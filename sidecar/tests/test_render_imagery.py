"""Render-imagery tests: POST /pipeline/render-imagery.

Test command (from sidecar/):
    SIDECAR_SHARED_SECRET=test-shared-secret uv run pytest tests/test_render_imagery.py -q

All tests are hermetic (no network).  The conftest sets IMAGERY_FIXTURE=1, so the
endpoint tests take the deterministic fixture path; the real Mapbox fetch is
covered separately with httpx stubbed (see the satellite-fetch tests below).

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
    monkeypatch.setenv("IMAGERY_FIXTURE", "1")
    body = _good_body(size_px=4096)
    response = client.post("/pipeline/render-imagery", headers=GOOD_BEARER, json=body)
    assert response.status_code == 200, (
        f"size_px=4096 should be accepted, got {response.status_code}: {response.text}"
    )


# ---------------------------------------------------------------------------
# Happy path — fixture path (IMAGERY_FIXTURE=1)
# ---------------------------------------------------------------------------


def test_render_imagery_happy_path_fixture_fallback(tmp_path, monkeypatch):
    """Fixture path (IMAGERY_FIXTURE=1): fixture PNG generated, stored, response valid."""
    monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
    monkeypatch.setenv("IMAGERY_FIXTURE", "1")

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

    # Attribution must include the Mapbox satellite entry
    assert len(resp.attribution) >= 1
    names = [a.name for a in resp.attribution]
    assert any("Mapbox" in n for n in names), f"Mapbox attribution missing, got {names}"

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
    monkeypatch.setenv("IMAGERY_FIXTURE", "1")
    response = client.post("/pipeline/render-imagery", headers=GOOD_BEARER, json=_good_body())
    assert response.status_code == 200, response.text
    assert response.json()["pipelineSchemaVersion"] == PIPELINE_SCHEMA_VERSION


def test_render_imagery_key_deterministic(tmp_path, monkeypatch):
    """Same polygon + size_px → same cache key on two calls."""
    monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
    monkeypatch.setenv("IMAGERY_FIXTURE", "1")

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
    monkeypatch.setenv("IMAGERY_FIXTURE", "1")

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
    monkeypatch.setenv("IMAGERY_FIXTURE", "1")

    response = client.post("/pipeline/render-imagery", headers=GOOD_BEARER, json=_good_body())
    assert response.status_code == 200, response.text
    assert "target_gsd_m_ignored" not in response.json()["warnings"]


def test_render_imagery_different_polygons_different_keys(tmp_path, monkeypatch):
    """Different polygon → different cache key."""
    monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
    monkeypatch.setenv("IMAGERY_FIXTURE", "1")

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
# Real Mapbox satellite fetch (the production imagery path)
# ---------------------------------------------------------------------------
#
# The real path hits the Mapbox Static Images API. We don't make a live network
# call in the hermetic suite; instead we stub httpx.get to assert the request is
# well-formed (bbox form, token, padding=0) and that the response is normalised
# to a square PNG at the requested size_px.


def test_fetch_satellite_png_calls_mapbox_static_and_normalises(monkeypatch):
    import io as _io

    import httpx
    from PIL import Image

    from app.imagery import naip

    monkeypatch.setenv("MAPBOX_PUBLIC_TOKEN", "pk.test-token")

    captured = {}

    def fake_get(url, **kwargs):
        captured["url"] = url
        # Return a non-square PNG to prove normalisation resizes it. Attach a
        # request so raise_for_status() can evaluate the (200) status.
        buf = _io.BytesIO()
        Image.new("RGB", (640, 480), (10, 20, 30)).save(buf, format="PNG")
        return httpx.Response(200, content=buf.getvalue(), request=httpx.Request("GET", url))

    monkeypatch.setattr(httpx, "get", fake_get)

    png = naip.fetch_satellite_png(-81.46, 41.36, -81.45, 41.37, 256)

    # Request shape: Mapbox static, bbox form, token, padding=0, no attribution/logo.
    assert "api.mapbox.com/styles/v1/mapbox/satellite-v9/static/" in captured["url"]
    assert "[-81.46,41.36,-81.45,41.37]" in captured["url"]
    assert "access_token=pk.test-token" in captured["url"]
    assert "padding=0" in captured["url"]
    # Response normalised to a square PNG at size_px.
    out = Image.open(_io.BytesIO(png))
    assert out.format == "PNG"
    assert out.size == (256, 256)


def test_fetch_satellite_png_without_token_raises(monkeypatch):
    monkeypatch.delenv("MAPBOX_PUBLIC_TOKEN", raising=False)
    from app.imagery import naip

    with pytest.raises(RuntimeError, match="MAPBOX_PUBLIC_TOKEN"):
        naip.fetch_satellite_png(-81.46, 41.36, -81.45, 41.37, 256)


def test_fetch_satellite_png_http_error_raises_without_leaking_token(monkeypatch):
    import httpx

    from app.imagery import naip

    monkeypatch.setenv("MAPBOX_PUBLIC_TOKEN", "pk.secret-token")

    def fake_get(url, **kwargs):
        return httpx.Response(401, content=b"Unauthorized", request=httpx.Request("GET", url))

    monkeypatch.setattr(httpx, "get", fake_get)

    with pytest.raises(RuntimeError) as exc:
        naip.fetch_satellite_png(-81.46, 41.36, -81.45, 41.37, 256)
    # The token must not appear in the error message.
    assert "pk.secret-token" not in str(exc.value)
