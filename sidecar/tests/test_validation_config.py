"""Schema + referential-integrity tests for the validation config files.

These enforce that test_addresses.yaml and ground_truth.yaml stay well-formed
and self-consistent (ADR-017). Entries flagged ``todo: true`` are
human-gated placeholders (the address pre-pick / EagleView / tape-measure /
assessor data collection is manual setup); they are checked for structure but
exempt from the live-data gates (WESM membership, positive areas) so CI is
green before the manual setup lands while the gate stays real once it does.
"""

from __future__ import annotations

import json
from pathlib import Path

import yaml

VALIDATION_DIR = Path(__file__).resolve().parent.parent / "validation"
ADDRESSES_PATH = VALIDATION_DIR / "test_addresses.yaml"
GROUND_TRUTH_PATH = VALIDATION_DIR / "ground_truth.yaml"
WESM_INDEX_PATH = VALIDATION_DIR / "fixtures" / "wesm_index.json"

COMPLEXITY_ENUM = {"simple", "moderate", "complex"}
REQUIRED_ADDRESS_FIELDS = {"address", "complexity", "region", "expected_wesm_work_unit"}
GROUND_TRUTH_KEYS = {"eagleview", "tape_measured", "county_assessor"}


def _load_yaml(path: Path):
    with path.open() as fh:
        return yaml.safe_load(fh)


def _wesm_names() -> set[str]:
    with WESM_INDEX_PATH.open() as fh:
        return {w["name"] for w in json.load(fh)}


def _addresses() -> list[dict]:
    return _load_yaml(ADDRESSES_PATH)["addresses"]


# --- test_addresses.yaml ----------------------------------------------------


def test_addresses_file_parses_and_is_a_list():
    data = _load_yaml(ADDRESSES_PATH)
    assert isinstance(data, dict)
    assert isinstance(data["addresses"], list)
    assert len(data["addresses"]) == 15, "ADR-017 stratified set is exactly 15 addresses"


def test_addresses_have_required_fields_and_valid_enums():
    for entry in _addresses():
        missing = REQUIRED_ADDRESS_FIELDS - entry.keys()
        assert not missing, f"address entry missing fields {missing}: {entry}"
        assert entry["complexity"] in COMPLEXITY_ENUM, entry["complexity"]
        assert str(entry["region"]).strip(), "region must be non-empty"
        assert str(entry["address"]).strip(), "address must be non-empty"


def test_addresses_are_stratified_5_5_5():
    counts = {c: 0 for c in COMPLEXITY_ENUM}
    for entry in _addresses():
        counts[entry["complexity"]] += 1
    assert counts == {"simple": 5, "moderate": 5, "complex": 5}, counts


def test_filled_addresses_reference_known_wesm_work_unit():
    """Non-placeholder entries must cite a work unit that exists in the index."""
    names = _wesm_names()
    for entry in _addresses():
        if entry.get("todo"):
            continue
        wu = entry["expected_wesm_work_unit"]
        assert wu in names, (
            f"expected_wesm_work_unit {wu!r} not in committed WESM index {sorted(names)}"
        )


def test_at_least_one_real_address_is_verified():
    """The gate must be live: at least one filled (non-TODO) entry must exist."""
    real = [e for e in _addresses() if not e.get("todo")]
    assert real, "every address is a TODO placeholder; at least one must be verified"


# --- ground_truth.yaml ------------------------------------------------------


def test_ground_truth_has_three_controls():
    data = _load_yaml(GROUND_TRUTH_PATH)
    assert GROUND_TRUTH_KEYS <= data.keys(), (
        f"ground_truth must define {GROUND_TRUTH_KEYS}, got {set(data.keys())}"
    )


def test_ground_truth_addresses_exist_in_test_addresses_when_filled():
    gt = _load_yaml(GROUND_TRUTH_PATH)
    addr_set = {e["address"] for e in _addresses()}
    for key in GROUND_TRUTH_KEYS:
        control = gt[key]
        if control.get("todo"):
            continue
        assert control["address"] in addr_set, (
            f"ground_truth.{key}.address {control['address']!r} not in test_addresses"
        )
        assert float(control["total_area_sq_ft"]) > 0
        assert float(control["predominant_pitch_ratio"]) >= 0.0


def test_ground_truth_entries_have_caveats():
    gt = _load_yaml(GROUND_TRUTH_PATH)
    for key in GROUND_TRUTH_KEYS:
        assert "caveats" in gt[key], f"ground_truth.{key} must document caveats"
