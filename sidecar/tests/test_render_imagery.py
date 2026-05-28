"""F-10.1 tests: POST /pipeline/render-imagery.

Test command (from sidecar/):
    SIDECAR_SHARED_SECRET=test-shared-secret uv run pytest tests/test_render_imagery.py -q

All tests are hermetic (no network).  The real NAIP path is guarded by
IMAGERY_LIVE=1; these tests never set it, so the fixture-fallback always runs.

Coverage:
  - Happy path (fixture fallback): 200, valid response, geo_bounds ordered,
    image_tile_ref starts with 'cache/', stored object exists in storage,
    'imagery_fixture_fallback' warning present.
  - Auth guards: no bearer → 401, wrong bearer → 401.
  - Bad polygon (out-of-range coords) → 422.
  - Version-major mismatch → 409.
  - Malformed body (missing required fields) → 422.
  - Pure unit tests for bbox math + fixture PNG generation (no HTTP).
"""

from __future__ import annotations

import io
import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.main import app
from app.imagery.naip import (
    bbox_cache_key,
    generate_fixture_png,
    polygon_to_padded_bbox,
)
from contracts.pipeline import (
    PIPELINE_SCHEMA_VERSION,
    RenderImageryResponse,
)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

GOOD_BEARER = {"Authorization": "Bearer test-shared-secret"}
BAD_BEARER = {"Authorization": "Bearer wrong-secret"}

REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = REPO_ROOT / "shared" / "pipeline_schema.json"
_SCHEMA = json.loads(SCHEMA_PATH.read_text())


# A simple rectangular roof polygon in Denver, CO (valid WGS84)
_DENVER_POLYGON = {
    "type": "Polygon",
    "coordinates": [[
        [-104.9950, 39.7380],
        [-104.9940, 39.7380],
        [-104.9940, 39.7390],
        [-104.9950, 39.7390],
        [-104.9950, 39.7380],
    ]],
}

# A polygon with out-of-range longitude (>180)
_BAD_POLYGON = {
    "type": "Polygon",
    "coordinates": [[
        [200.0, 39.7380],
        [201.0, 39.7380],
        [201.0, 39.7390],
        [200.0, 39.7390],
        [200.0, 39.7380],
    ]],
}


def _good_body(size_px: int = 128) -> dict:
    return {
        "pipelineSchemaVersion": PIPELINE_SCHEMA_VERSION,
        "building_polygon": _DENVER_POLYGON,
        "size_px": size_px,
    }


client = TestClient(app)


# ---------------------------------------------------------------------------
# Auth guard tests
# ---------------------------------------------------------------------------


def test_render_imagery_requires_bearer():
    response = client.post("/pipeline/render-imagery", json=_good_body())
    assert response.status_code == 401


def test_render_imagery_rejects_wrong_bearer():
    response = client.post(
        "/pipeline/render-imagery", headers=BAD_BEARER, json=_good_body()
    )
    assert response.status_code == 401


# ---------------------------------------------------------------------------
# Schema version guard
# ---------------------------------------------------------------------------


def test_render_imagery_rejects_wrong_major_version():
    body = _good_body()
    body["pipelineSchemaVersion"] = "9.0.0"
    response = client.post("/pipeline/render-imagery", headers=GOOD_BEARER, json=body)
    assert response.status_code == 409, response.text


# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------


def test_render_imagery_rejects_out_of_range_coords(tmp_path, monkeypatch):
    monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
    body = _good_body()
    body["building_polygon"] = _BAD_POLYGON
    response = client.post("/pipeline/render-imagery", headers=GOOD_BEARER, json=body)
    assert response.status_code == 422, response.text


def test_render_imagery_rejects_malformed_body():
    response = client.post(
        "/pipeline/render-imagery",
        headers=GOOD_BEARER,
        json={"pipelineSchemaVersion": PIPELINE_SCHEMA_VERSION},  # missing required fields
    )
    assert response.status_code == 422


def test_render_imagery_rejects_size_px_above_maximum():
    """size_px > 4096 must be rejected with 422 (Pydantic le=4096 constraint)."""
    body = _good_body(size_px=5000)
    response = client.post("/pipeline/render-imagery", headers=GOOD_BEARER, json=body)
    assert response.status_code == 422, (
        f"size_px=5000 should be rejected (max 4096), got {response.status_code}: {response.text}"
    )


def test_render_imagery_accepts_size_px_at_maximum(tmp_path, monkeypatch):
    """size_px=4096 is exactly at the upper bound and must be accepted."""
    monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
    monkeypatch.delenv("IMAGERY_LIVE", raising=False)
    body = _good_body(size_px=4096)
    response = client.post("/pipeline/render-imagery", headers=GOOD_BEARER, json=body)
    assert response.status_code == 200, (
        f"size_px=4096 should be accepted, got {response.status_code}: {response.text}"
    )


# ---------------------------------------------------------------------------
# Happy path — fixture fallback (IMAGERY_LIVE unset)
# ---------------------------------------------------------------------------


def test_render_imagery_happy_path_fixture_fallback(tmp_path, monkeypatch):
    """Default (no IMAGERY_LIVE): fixture PNG generated, stored, response valid."""
    monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
    monkeypatch.delenv("IMAGERY_LIVE", raising=False)

    response = client.post("/pipeline/render-imagery", headers=GOOD_BEARER, json=_good_body())
    assert response.status_code == 200, response.text

    body = response.json()

    # Pydantic validation
    resp = RenderImageryResponse.model_validate(body)
    assert resp.pipelineSchemaVersion == PIPELINE_SCHEMA_VERSION

    # image_tile_ref must be a cache/ key
    assert resp.image_tile_ref.startswith("cache/"), (
        f"image_tile_ref should start with 'cache/', got {resp.image_tile_ref!r}"
    )

    # geo_bounds must be exactly 4 numbers and ordered [W<E, S<N]
    bounds = resp.image_geo_bounds
    assert len(bounds) == 4, f"expected 4 bounds, got {len(bounds)}"
    west, south, east, north = bounds
    assert west < east, f"west ({west}) >= east ({east})"
    assert south < north, f"south ({south}) >= north ({north})"

    # Fixture-fallback warning must be present
    assert "imagery_fixture_fallback" in resp.warnings, (
        f"expected 'imagery_fixture_fallback' in warnings, got {resp.warnings}"
    )

    # Attribution must include USDA NAIP entry
    assert len(resp.attribution) >= 1
    names = [a.name for a in resp.attribution]
    assert any("NAIP" in n for n in names), f"NAIP attribution missing, got {names}"

    # The PNG must have been stored to the local storage root
    stored_path = tmp_path / resp.image_tile_ref
    assert stored_path.exists(), f"stored PNG not found at {stored_path}"
    assert stored_path.stat().st_size > 0

    # The stored bytes must be a valid PNG
    with Image.open(stored_path) as img:
        assert img.format == "PNG"
        assert img.width > 0 and img.height > 0


def test_render_imagery_response_contains_schema_version(tmp_path, monkeypatch):
    monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
    monkeypatch.delenv("IMAGERY_LIVE", raising=False)
    response = client.post("/pipeline/render-imagery", headers=GOOD_BEARER, json=_good_body())
    assert response.status_code == 200, response.text
    assert response.json()["pipelineSchemaVersion"] == PIPELINE_SCHEMA_VERSION


def test_render_imagery_key_deterministic(tmp_path, monkeypatch):
    """Same polygon + size_px → same cache key on two calls."""
    monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
    monkeypatch.delenv("IMAGERY_LIVE", raising=False)

    r1 = client.post("/pipeline/render-imagery", headers=GOOD_BEARER, json=_good_body())
    r2 = client.post("/pipeline/render-imagery", headers=GOOD_BEARER, json=_good_body())
    assert r1.status_code == 200
    assert r2.status_code == 200
    assert r1.json()["image_tile_ref"] == r2.json()["image_tile_ref"], (
        "Same polygon + size_px should produce the same cache key"
    )


def test_render_imagery_warns_when_target_gsd_m_passed(tmp_path, monkeypatch):
    """A non-nil target_gsd_m is not yet honoured → 'target_gsd_m_ignored' warning."""
    monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
    monkeypatch.delenv("IMAGERY_LIVE", raising=False)

    body = _good_body()
    body["target_gsd_m"] = 0.3
    response = client.post("/pipeline/render-imagery", headers=GOOD_BEARER, json=body)
    assert response.status_code == 200, response.text
    warnings = response.json()["warnings"]
    assert "target_gsd_m_ignored" in warnings, (
        f"expected 'target_gsd_m_ignored' when target_gsd_m is passed, got {warnings}"
    )


def test_render_imagery_no_gsd_warning_when_omitted(tmp_path, monkeypatch):
    """Omitting target_gsd_m must NOT emit the ignored warning."""
    monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
    monkeypatch.delenv("IMAGERY_LIVE", raising=False)

    response = client.post("/pipeline/render-imagery", headers=GOOD_BEARER, json=_good_body())
    assert response.status_code == 200, response.text
    assert "target_gsd_m_ignored" not in response.json()["warnings"]


def test_render_imagery_different_polygons_different_keys(tmp_path, monkeypatch):
    """Different polygon → different cache key."""
    monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
    monkeypatch.delenv("IMAGERY_LIVE", raising=False)

    body1 = _good_body()
    body2 = _good_body()
    body2["building_polygon"] = {
        "type": "Polygon",
        "coordinates": [[
            [-87.6300, 41.8827],
            [-87.6290, 41.8827],
            [-87.6290, 41.8837],
            [-87.6300, 41.8837],
            [-87.6300, 41.8827],
        ]],
    }

    r1 = client.post("/pipeline/render-imagery", headers=GOOD_BEARER, json=body1)
    r2 = client.post("/pipeline/render-imagery", headers=GOOD_BEARER, json=body2)
    assert r1.status_code == 200
    assert r2.status_code == 200
    assert r1.json()["image_tile_ref"] != r2.json()["image_tile_ref"], (
        "Different polygons should produce different cache keys"
    )


# ---------------------------------------------------------------------------
# Unit tests for pure helpers (no HTTP, no storage)
# ---------------------------------------------------------------------------


def test_polygon_to_padded_bbox_basic():
    """Padded bbox must contain the original bbox and be wider/taller."""
    west, south, east, north = polygon_to_padded_bbox(_DENVER_POLYGON)
    lons = [c[0] for c in _DENVER_POLYGON["coordinates"][0]]
    lats = [c[1] for c in _DENVER_POLYGON["coordinates"][0]]
    raw_w, raw_e = min(lons), max(lons)
    raw_s, raw_n = min(lats), max(lats)

    assert west < raw_w, "padded west should be west of raw west"
    assert east > raw_e, "padded east should be east of raw east"
    assert south < raw_s, "padded south should be south of raw south"
    assert north > raw_n, "padded north should be north of raw north"
    assert west < east
    assert south < north


def test_polygon_to_padded_bbox_clamped():
    """Padding must not produce out-of-range lon/lat."""
    # Polygon near the north pole, should clamp to 90.
    near_pole = {
        "type": "Polygon",
        "coordinates": [[
            [-1.0, 89.5],
            [1.0, 89.5],
            [1.0, 89.9],
            [-1.0, 89.9],
            [-1.0, 89.5],
        ]],
    }
    west, south, east, north = polygon_to_padded_bbox(near_pole)
    assert north <= 90.0
    assert south >= -90.0
    assert west >= -180.0
    assert east <= 180.0


def test_bbox_cache_key_format():
    """Cache key must match the expected pattern."""
    key = bbox_cache_key(-105.0, 39.7, -104.9, 39.8, 256)
    assert key.startswith("cache/imagery/")
    assert key.endswith(".png")
    # Hash portion is 24 hex chars
    stem = key[len("cache/imagery/"):-len(".png")]
    assert len(stem) == 24, f"hash stem should be 24 chars, got {len(stem)}: {stem!r}"
    assert all(c in "0123456789abcdef" for c in stem)


def test_bbox_cache_key_deterministic():
    """Same inputs → same key."""
    k1 = bbox_cache_key(-105.0, 39.7, -104.9, 39.8, 256)
    k2 = bbox_cache_key(-105.0, 39.7, -104.9, 39.8, 256)
    assert k1 == k2


def test_bbox_cache_key_differs_on_different_size():
    """Different size_px → different key."""
    k1 = bbox_cache_key(-105.0, 39.7, -104.9, 39.8, 128)
    k2 = bbox_cache_key(-105.0, 39.7, -104.9, 39.8, 256)
    assert k1 != k2


def test_generate_fixture_png_is_valid_png():
    """Fixture PNG must be a valid RGB image of the requested size."""
    png_bytes = generate_fixture_png(-105.0, 39.7, -104.9, 39.8, 64)
    assert len(png_bytes) > 0
    with Image.open(io.BytesIO(png_bytes)) as img:
        assert img.format == "PNG"
        assert img.mode == "RGB"
        assert img.width == 64
        assert img.height == 64


def test_generate_fixture_png_deterministic():
    """Same bbox → same bytes."""
    b1 = generate_fixture_png(-105.0, 39.7, -104.9, 39.8, 32)
    b2 = generate_fixture_png(-105.0, 39.7, -104.9, 39.8, 32)
    assert b1 == b2


def test_generate_fixture_png_differs_by_bbox():
    """Different bboxes → different images (different seeds)."""
    b1 = generate_fixture_png(-105.0, 39.7, -104.9, 39.8, 32)
    b2 = generate_fixture_png(-87.6, 41.8, -87.5, 41.9, 32)
    assert b1 != b2


# ---------------------------------------------------------------------------
# project_bounds — the WGS84 → projected read-window helper (CRS bug fix)
# ---------------------------------------------------------------------------
#
# NAIP COGs are stored in a projected CRS (UTM). The window for a windowed read
# must be computed from bounds *in that CRS*, not from raw WGS84 lon/lat
# degrees. These tests build a synthetic UTM 13N raster covering a Denver bbox
# and prove the new helper produces a sane pixel-space window, whereas feeding
# raw degrees to the COG's projected transform (the old code) does not.


def _denver_wgs84_bounds() -> tuple[float, float, float, float]:
    return (-104.9950, 39.7380, -104.9940, 39.7390)


def test_project_bounds_returns_sane_pixel_window_for_utm_cog():
    """Window for a UTM COG must land on real, in-raster pixels."""
    from rasterio.crs import CRS
    from rasterio.transform import from_origin
    from rasterio.warp import transform_bounds

    from app.imagery.naip import project_bounds

    wgs84 = _denver_wgs84_bounds()
    utm = CRS.from_epsg(32613)  # UTM zone 13N — covers Denver
    # COG origin 1000 m NW of the projected bbox, 1 m pixels.
    pw, ps, pe, pn = transform_bounds("EPSG:4326", utm, *wgs84, densify_pts=21)
    transform = from_origin(pw - 1000.0, pn + 1000.0, 1.0, 1.0)

    win = project_bounds(utm, transform, wgs84)

    # The projected bbox is ~85 m x ~111 m → roughly that many 1 m pixels.
    assert 50 < win.width < 200, f"window width should be tens of px, got {win.width}"
    assert 50 < win.height < 200, f"window height should be tens of px, got {win.height}"
    # Offsets must be positive and within the modelled raster, not far off-grid.
    assert 0 <= win.col_off < 2000, f"col_off out of range: {win.col_off}"
    assert 0 <= win.row_off < 2000, f"row_off out of range: {win.row_off}"


def test_project_bounds_differs_from_raw_degree_window():
    """Prove the bug fix: raw-degree windowing (old code) is wildly wrong.

    The old code passed WGS84 degrees straight to ``from_bounds`` against the
    COG's projected (UTM, metres) transform. That yields a degenerate sub-pixel
    window placed hundreds of thousands of pixels off the raster. The fixed
    helper transforms to the COG CRS first, producing a real window.
    """
    from rasterio.crs import CRS
    from rasterio.transform import from_origin
    from rasterio.warp import transform_bounds
    from rasterio.windows import from_bounds as win_from_bounds

    from app.imagery.naip import project_bounds

    wgs84 = _denver_wgs84_bounds()
    west, south, east, north = wgs84
    utm = CRS.from_epsg(32613)
    pw, ps, pe, pn = transform_bounds("EPSG:4326", utm, *wgs84, densify_pts=21)
    transform = from_origin(pw - 1000.0, pn + 1000.0, 1.0, 1.0)

    new_win = project_bounds(utm, transform, wgs84)
    # OLD behaviour: feed raw degrees to the projected transform.
    old_win = win_from_bounds(west, south, east, north, transform=transform)

    # Old window is degenerate (sub-pixel) because 0.001 degrees is read as
    # 0.001 metres against the 1 m grid.
    assert old_win.width < 1.0 and old_win.height < 1.0, (
        f"expected degenerate old window, got {old_win}"
    )
    # Old window is also placed wildly off-grid (huge negative col_off).
    assert old_win.col_off < -1000, f"expected far-off old col_off, got {old_win.col_off}"

    # New window is a real, multi-pixel window inside the raster.
    assert new_win.width > 50 and new_win.height > 50
    assert 0 <= new_win.col_off < 2000 and 0 <= new_win.row_off < 2000


def test_project_bounds_identity_when_crs_already_4326():
    """When the COG CRS is already EPSG:4326, transform_bounds is a no-op and
    the window matches a direct degree-based read (degrees-on-degrees grid)."""
    from rasterio.crs import CRS
    from rasterio.transform import from_origin
    from rasterio.windows import from_bounds as win_from_bounds

    from app.imagery.naip import project_bounds

    wgs84 = _denver_wgs84_bounds()
    west, south, east, north = wgs84
    crs4326 = CRS.from_epsg(4326)
    # A degree-gridded raster (e.g. 0.0001 deg/px) with origin NW of the bbox.
    transform = from_origin(west - 0.01, north + 0.01, 0.0001, 0.0001)

    win = project_bounds(crs4326, transform, wgs84)
    direct = win_from_bounds(west, south, east, north, transform=transform)

    assert win.width == pytest.approx(direct.width, rel=1e-6)
    assert win.height == pytest.approx(direct.height, rel=1e-6)
    assert win.col_off == pytest.approx(direct.col_off, rel=1e-6)
    assert win.row_off == pytest.approx(direct.row_off, rel=1e-6)
