"""Integrity tests for the feature-detection eval dataset (ADR-006).

A broken or partial dataset must fail loudly, not silently skew the model
comparison. These assert manifest<->labels consistency, in-bounds bboxes, the
fixed vocabulary, and at least one true-negative tile. The live satellite
(Mapbox) fetch path in pull_tiles is exercised by a separate slow test (skipped
by default).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

FD_DIR = Path(__file__).resolve().parent.parent / "validation" / "feature_detection"
MANIFEST_PATH = FD_DIR / "manifest.json"
LABELS_PATH = FD_DIR / "labels.json"
KNOWN_LABELS_PATH = FD_DIR / "known_labels.json"

REQUIRED_MANIFEST_FIELDS = {
    "tile_id",
    "address",
    "bbox",
    "gsd_cm",
    "provider",
    "capture_date",
    "source_url",
    "license",
}


def _load(path: Path):
    with path.open() as fh:
        return json.load(fh)


def _known_labels() -> set[str]:
    return set(_load(KNOWN_LABELS_PATH)["labels"])


def _manifest() -> list[dict]:
    return _load(MANIFEST_PATH)["tiles"]


def _labels() -> dict:
    return _load(LABELS_PATH)["tiles"]


def test_known_labels_is_the_fixed_vocabulary():
    assert _known_labels() == {"chimney", "vent", "skylight", "dormer", "satellite_dish"}


def test_manifest_and_labels_have_no_orphans():
    manifest_ids = {t["tile_id"] for t in _manifest()}
    label_ids = set(_labels().keys())
    assert manifest_ids == label_ids, (
        f"manifest/labels tile_id mismatch: "
        f"only in manifest={manifest_ids - label_ids}, "
        f"only in labels={label_ids - manifest_ids}"
    )


def test_manifest_entries_have_provenance_fields():
    for tile in _manifest():
        missing = REQUIRED_MANIFEST_FIELDS - tile.keys()
        assert not missing, f"manifest tile {tile.get('tile_id')} missing {missing}"
        assert len(tile["bbox"]) == 4, "bbox must be [min_lon,min_lat,max_lon,max_lat]"


def test_all_label_bboxes_in_bounds_and_in_vocabulary():
    vocab = _known_labels()
    for tile_id, tile in _labels().items():
        for feat in tile.get("features", []):
            assert feat["label"] in vocab, (
                f"{tile_id}: out-of-vocab label {feat['label']!r}"
            )
            box = feat["bbox_norm"]
            assert len(box) == 4, f"{tile_id}: bbox_norm must have 4 values"
            assert box[0] <= box[2] and box[1] <= box[3], f"{tile_id}: inverted bbox {box}"
            for v in box:
                assert 0.0 <= v <= 1.0, f"{tile_id}: bbox_norm value {v} out of [0,1]"


def test_at_least_one_true_negative_tile():
    """Precision needs roofs with no features; assert >= 1 such tile exists."""
    negatives = [tid for tid, t in _labels().items() if not t.get("features")]
    assert negatives, "dataset must include >= 1 true-negative tile (no features)"


def test_pull_tiles_only_references_allowlisted_imagery_hosts():
    """SSRF: pull_tiles must fetch only via the production imagery path.

    The fetcher (sidecar.app.imagery.naip) talks to the allowlisted Mapbox
    Static Images host and nothing else; pull_tiles reuses it rather than
    fetching arbitrary URLs. Assert pull_tiles imports the production fetcher
    and does not open arbitrary http(s) URLs itself.
    """
    src = (FD_DIR / "pull_tiles.py").read_text()
    assert "fetch_satellite_png" in src, "pull_tiles must reuse the production imagery fetcher"
    # No ad-hoc URL fetching in pull_tiles (the host allowlist lives in naip.py).
    for forbidden in ("httpx.get(", "requests.get(", "urlopen("):
        assert forbidden not in src, f"pull_tiles must not fetch directly: {forbidden}"
