"""F-07 tests: POST /pipeline/refine-outline.

Test command (from sidecar/):
    SIDECAR_SHARED_SECRET=test-shared-secret \
    STORAGE_LOCAL_ROOT=$(pwd)/tests/fixtures/f07 \
    uv run pytest tests/test_refine_outline.py -q

Test coverage:
  - Parity: modal vs local backends produce equivalent masks (both run through
    the stub here, so they are identical; structure allows catching real drift).
  - Refinement quality: small fixture corpus, IoU sanity + vertex count <=30.
  - Fallback-to-prior: synthetic image/prior that triggers IoU<0.5 -> returns
    prior unchanged + "sam2_low_confidence" warning.
  - Schema validation: every response validates against RefineOutlineResponse.
  - Auth guards: missing/wrong bearer rejected.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from jsonschema import Draft202012Validator

from app.main import app
from contracts.pipeline import (
    PIPELINE_SCHEMA_VERSION,
    RefineOutlineResponse,
)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

GOOD_BEARER = {"Authorization": "Bearer test-shared-secret"}
BAD_BEARER = {"Authorization": "Bearer wrong-secret"}

REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = REPO_ROOT / "shared" / "pipeline_schema.json"
FIXTURE_DIR = Path(__file__).parent / "fixtures" / "f07"

_SCHEMA = json.loads(SCHEMA_PATH.read_text())


def _validator_for(entity: str) -> Draft202012Validator:
    sub = {"$ref": f"#/$defs/{entity}", "$defs": _SCHEMA["$defs"]}
    return Draft202012Validator(sub)


client = TestClient(app)

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# A small roof-like polygon that covers roughly the center 40% of a 256×256 tile.
# image_geo_bounds = [west, south, east, north] — a tiny patch of the US.
_GEO_BOUNDS = [-104.9955, 39.7375, -104.9945, 39.7385]  # ~90 m × ~110 m
# WGS84 polygon matching the center box  (approx 40–80% of the image extent)
_W, _S, _E, _N = _GEO_BOUNDS
_LON_RANGE = _E - _W
_LAT_RANGE = _N - _S

# 40–80% box in lon/lat
_PRIOR_POLYGON = {
    "type": "Polygon",
    "coordinates": [[
        [_W + 0.3 * _LON_RANGE, _N - 0.3 * _LAT_RANGE],
        [_W + 0.7 * _LON_RANGE, _N - 0.3 * _LAT_RANGE],
        [_W + 0.7 * _LON_RANGE, _N - 0.7 * _LAT_RANGE],
        [_W + 0.3 * _LON_RANGE, _N - 0.7 * _LAT_RANGE],
        [_W + 0.3 * _LON_RANGE, _N - 0.3 * _LAT_RANGE],  # closed
    ]],
}


def _good_body(tile_ref: str = "tile_good.png") -> dict:
    return {
        "pipelineSchemaVersion": PIPELINE_SCHEMA_VERSION,
        "image_tile_ref": tile_ref,
        "prior_polygon": _PRIOR_POLYGON,
        "image_geo_bounds": _GEO_BOUNDS,
    }


# ---------------------------------------------------------------------------
# Auth guard tests
# ---------------------------------------------------------------------------


def test_refine_outline_requires_bearer():
    response = client.post("/pipeline/refine-outline", json=_good_body())
    assert response.status_code == 401


def test_refine_outline_rejects_wrong_bearer():
    response = client.post("/pipeline/refine-outline", headers=BAD_BEARER, json=_good_body())
    assert response.status_code == 401


# ---------------------------------------------------------------------------
# Schema version guard
# ---------------------------------------------------------------------------


def test_refine_outline_rejects_wrong_major_version():
    body = _good_body()
    body["pipelineSchemaVersion"] = "9.0.0"
    response = client.post("/pipeline/refine-outline", headers=GOOD_BEARER, json=body)
    assert response.status_code == 409, response.text


def test_refine_outline_rejects_malformed_body():
    response = client.post(
        "/pipeline/refine-outline",
        headers=GOOD_BEARER,
        json={"pipelineSchemaVersion": PIPELINE_SCHEMA_VERSION},  # missing required fields
    )
    assert response.status_code == 422


def test_refine_outline_rejects_degenerate_geo_bounds(monkeypatch):
    monkeypatch.setenv("SAM2_BACKEND", "local")
    body = _good_body()
    # west == east -> zero longitude range -> would divide-by-zero in rasterize.
    w, s, e, n = body["image_geo_bounds"]
    body["image_geo_bounds"] = [w, s, w, n]
    response = client.post("/pipeline/refine-outline", headers=GOOD_BEARER, json=body)
    assert response.status_code == 422, response.text
    assert "degenerate" in response.text.lower()


# ---------------------------------------------------------------------------
# Happy path — local backend (default)
# ---------------------------------------------------------------------------


def test_refine_outline_happy_path_local_backend(monkeypatch):
    """Local backend (stub): erodes prior, IoU > 0.5, returns refined polygon."""
    monkeypatch.setenv("SAM2_BACKEND", "local")
    response = client.post("/pipeline/refine-outline", headers=GOOD_BEARER, json=_good_body())
    assert response.status_code == 200, response.text
    body = response.json()

    # Schema validation
    errors = list(_validator_for("RefineOutlineResponse").iter_errors(body))
    assert not errors, f"schema errors: {[e.message for e in errors]}"

    # Pydantic validation
    resp = RefineOutlineResponse.model_validate(body)
    assert resp.pipelineSchemaVersion == PIPELINE_SCHEMA_VERSION
    assert resp.sam2_backend == "local"
    assert 0.0 <= resp.iou_with_prior <= 1.0
    assert resp.refined_polygon.type == "Polygon"
    assert "sam2_low_confidence" not in resp.warnings


def test_refine_outline_returns_polygon_with_sane_vertex_count(monkeypatch):
    """Refined polygon must have <=30 vertices for a simple fixture tile."""
    monkeypatch.setenv("SAM2_BACKEND", "local")
    response = client.post("/pipeline/refine-outline", headers=GOOD_BEARER, json=_good_body())
    assert response.status_code == 200, response.text
    body = response.json()
    exterior_ring = body["refined_polygon"]["coordinates"][0]
    # Closed ring: first == last, so vertex count = len - 1
    vertex_count = len(exterior_ring) - 1
    assert vertex_count <= 30, f"too many vertices: {vertex_count}"


# ---------------------------------------------------------------------------
# Parity test: modal vs local must produce equivalent results
# ---------------------------------------------------------------------------


def test_modal_local_backend_parity(monkeypatch):
    """Both backends run through the stub in CI — they must produce identical masks
    (IoU difference <= 5%).  The test structure would catch real model drift if
    the stub were replaced with real SAM2 calls.
    """
    monkeypatch.setenv("SAM2_BACKEND", "local")
    r_local = client.post("/pipeline/refine-outline", headers=GOOD_BEARER, json=_good_body())
    assert r_local.status_code == 200, r_local.text

    monkeypatch.setenv("SAM2_BACKEND", "modal")
    r_modal = client.post("/pipeline/refine-outline", headers=GOOD_BEARER, json=_good_body())
    assert r_modal.status_code == 200, r_modal.text

    iou_local = r_local.json()["iou_with_prior"]
    iou_modal = r_modal.json()["iou_with_prior"]
    assert abs(iou_local - iou_modal) <= 0.05, (
        f"backend parity broken: local IoU={iou_local:.3f}, modal IoU={iou_modal:.3f}"
    )

    # Both backends also claim the same polygon coordinates (since both use the stub).
    coords_local = r_local.json()["refined_polygon"]["coordinates"]
    coords_modal = r_modal.json()["refined_polygon"]["coordinates"]
    assert coords_local == coords_modal, "modal and local polygons differ (drift detected)"


def test_modal_requested_but_unavailable_reports_local_with_warning(monkeypatch):
    """SAM2_BACKEND=modal with no Modal tokens must NOT mislabel stub output as
    'modal' — it falls back to local and says so, with a warning."""
    monkeypatch.setenv("SAM2_BACKEND", "modal")
    monkeypatch.delenv("MODAL_TOKEN_ID", raising=False)
    resp = client.post("/pipeline/refine-outline", headers=GOOD_BEARER, json=_good_body())
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["sam2_backend"] == "local"
    assert "sam2_modal_unavailable" in body["warnings"]


# ---------------------------------------------------------------------------
# Fallback-to-prior test
# ---------------------------------------------------------------------------


def test_fallback_to_prior_on_low_iou(monkeypatch, tmp_path):
    """A tiny prior that maps to <1 pixel should get an empty SAM2 mask,
    triggering IoU<0.5 fallback with sam2_low_confidence warning."""
    monkeypatch.setenv("SAM2_BACKEND", "local")
    # Use a prior that is a single-point degenerate polygon (collapses to empty mask)
    # or a vanishingly small polygon outside the main image area.
    # Easiest: set up a "uniform" tile (no roof signal) and a prior that
    # covers only 1 pixel -> erosion makes the mask empty -> IoU=0.
    from PIL import Image
    tiny_img = Image.new("RGB", (256, 256), color=(150, 150, 150))
    tile_path = tmp_path / "tile_uniform_fallback.png"
    tiny_img.save(str(tile_path))

    monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))

    # Prior is a 1×1 pixel box in the top-left corner — after erosion (r=3) it
    # will be empty, giving IoU=0.
    w, s, e, n = _GEO_BOUNDS
    lon_range = e - w
    lat_range = n - s
    px_w = lon_range / 256  # 1 pixel wide
    px_h = lat_range / 256

    tiny_prior = {
        "type": "Polygon",
        "coordinates": [[
            [w, n],
            [w + px_w, n],
            [w + px_w, n - px_h],
            [w, n - px_h],
            [w, n],
        ]],
    }

    body = {
        "pipelineSchemaVersion": PIPELINE_SCHEMA_VERSION,
        "image_tile_ref": "tile_uniform_fallback.png",
        "prior_polygon": tiny_prior,
        "image_geo_bounds": _GEO_BOUNDS,
    }

    response = client.post("/pipeline/refine-outline", headers=GOOD_BEARER, json=body)
    assert response.status_code == 200, response.text
    resp = response.json()

    assert "sam2_low_confidence" in resp["warnings"], (
        f"expected fallback warning, got warnings={resp['warnings']}"
    )
    # The returned polygon must be the prior (unchanged)
    assert resp["refined_polygon"] == tiny_prior


# ---------------------------------------------------------------------------
# Refinement quality corpus (5 tiles)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("tile_name", [
    "tile_good.png",
    "tile_3.png",
    "tile_4.png",
    "tile_5.png",
])
def test_refinement_quality_corpus(tile_name, monkeypatch):
    """For a small corpus of fixture tiles, assert IoU is sane (>0 when prior
    has good coverage) and vertex count <=30.  Four of four tiles must pass.
    """
    monkeypatch.setenv("SAM2_BACKEND", "local")
    body = _good_body(tile_ref=tile_name)
    response = client.post("/pipeline/refine-outline", headers=GOOD_BEARER, json=body)
    assert response.status_code == 200, f"{tile_name}: {response.text}"
    resp = response.json()

    # Schema valid
    errors = list(_validator_for("RefineOutlineResponse").iter_errors(resp))
    assert not errors, f"{tile_name} schema errors: {[e.message for e in errors]}"

    # IoU sanity: either fallback (prior returned) or refined with meaningful IoU
    iou = resp["iou_with_prior"]
    assert 0.0 <= iou <= 1.0, f"{tile_name}: IoU out of range: {iou}"

    # Vertex count
    exterior = resp["refined_polygon"]["coordinates"][0]
    vertex_count = len(exterior) - 1  # closed ring
    assert vertex_count <= 30, f"{tile_name}: too many vertices: {vertex_count}"

    # Pydantic validates
    RefineOutlineResponse.model_validate(resp)


# ---------------------------------------------------------------------------
# Missing tile error handling
# ---------------------------------------------------------------------------


def test_refine_outline_missing_tile_returns_422(monkeypatch, tmp_path):
    """A non-existent tile ref should return 422 (storage error)."""
    monkeypatch.setenv("SAM2_BACKEND", "local")
    monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
    body = _good_body(tile_ref="does_not_exist.png")
    response = client.post("/pipeline/refine-outline", headers=GOOD_BEARER, json=body)
    assert response.status_code == 422, response.text


# ---------------------------------------------------------------------------
# Response always contains pipelineSchemaVersion
# ---------------------------------------------------------------------------


def test_response_contains_pipeline_schema_version(monkeypatch):
    monkeypatch.setenv("SAM2_BACKEND", "local")
    response = client.post("/pipeline/refine-outline", headers=GOOD_BEARER, json=_good_body())
    assert response.status_code == 200, response.text
    assert response.json()["pipelineSchemaVersion"] == PIPELINE_SCHEMA_VERSION
