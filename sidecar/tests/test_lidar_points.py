"""LiDAR-points overlay endpoint tests (POST /pipeline/lidar-points).

Exercises the decode -> downsample -> UTM->WGS84 -> meters->feet path that feeds
the interactive report overlay (ADR-013), plus the contract mapping and the
not-found / too-large / schema-mismatch guards. No PDAL/network: the cropped
array is seeded through the same real storage helper the ingest stage writes
with, pointed at a temp dir.
"""

from __future__ import annotations

import io
import json
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient
from jsonschema import Draft202012Validator

from app.lidar import ingest as ingest_mod
from app.lidar.ingest import load_overlay_points

REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA = json.loads((REPO_ROOT / "shared" / "pipeline_schema.json").read_text())
GOOD_BEARER = {"Authorization": "Bearer test-shared-secret"}

# A patch of points in UTM 14N (EPSG:32614), near Lincoln NE. x,y in meters,
# z in meters, classification in col 3 (matching the cached array shape).
UTM_ZONE = 32614

# A small Lincoln, NE building footprint; its centroid lands in UTM 14N (32614),
# the zone the synthetic points are authored in. The endpoint derives the zone
# from this polygon's centroid (the same function the ingest used).
LINCOLN_BUILDING = {
    "type": "Polygon",
    "coordinates": [
        [
            [-96.7026, 40.8136],
            [-96.7022, 40.8136],
            [-96.7022, 40.8139],
            [-96.7026, 40.8139],
            [-96.7026, 40.8136],
        ]
    ],
}


def _validator(entity: str) -> Draft202012Validator:
    return Draft202012Validator({"$ref": f"#/$defs/{entity}", "$defs": SCHEMA["$defs"]})


def _synthetic_array(n: int) -> np.ndarray:
    # A tight cluster of roof returns around a plausible UTM 14N easting/northing.
    rng = np.linspace(0.0, 10.0, n)
    x = 694000.0 + rng
    y = 4521000.0 + rng
    z = 330.0 + (rng * 0.1)  # ~330 m elevation
    cls = np.full(n, 6.0)
    return np.column_stack([x, y, z, cls])


@pytest.fixture
def client(monkeypatch, tmp_path):
    monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
    from app.main import app

    return TestClient(app)


def _seed_array(tmp_root: Path, key: str, arr: np.ndarray) -> None:
    buf = io.BytesIO()
    np.save(buf, arr)
    path = tmp_root / key
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(buf.getvalue())


# ---------------------------------------------------------------------------
# Core: load_overlay_points
# ---------------------------------------------------------------------------


def test_load_overlay_points_reprojects_to_wgs84_feet():
    arr = _synthetic_array(100)
    buf = io.BytesIO()
    np.save(buf, arr)
    out = load_overlay_points(buf.getvalue(), utm_zone=UTM_ZONE, max_points=1000)

    assert out.point_count == 100
    assert out.returned_count == 100
    assert len(out.points) == 100
    # Reprojected lon/lat land near Lincoln NE.
    lon, lat, elev_ft = out.points[0]
    assert -97.0 < lon < -96.0
    assert 40.0 < lat < 41.0
    # 330 m -> ~1082 ft.
    assert 1080.0 < elev_ft < 1085.0
    # bounds bracket the points.
    assert out.bounds[0] <= lon <= out.bounds[2]
    assert out.bounds[1] <= lat <= out.bounds[3]


def test_load_overlay_points_downsamples_to_cap():
    arr = _synthetic_array(5000)
    buf = io.BytesIO()
    np.save(buf, arr)
    out = load_overlay_points(buf.getvalue(), utm_zone=UTM_ZONE, max_points=500)
    assert out.point_count == 5000
    assert out.returned_count == 500


def test_load_overlay_points_empty_array():
    arr = np.empty((0, 4))
    buf = io.BytesIO()
    np.save(buf, arr)
    out = load_overlay_points(buf.getvalue(), utm_zone=UTM_ZONE)
    assert out.point_count == 0
    assert out.returned_count == 0
    assert out.points == []
    assert out.bounds is None


# ---------------------------------------------------------------------------
# Endpoint
# ---------------------------------------------------------------------------


def _body(ref: str, **kw) -> dict:
    return {
        "pipelineSchemaVersion": "0.6.0",
        "point_array_ref": ref,
        "building_polygon": LINCOLN_BUILDING,
        **kw,
    }


def test_endpoint_returns_overlay_points(client, tmp_path):
    key = "cache/lidar/deadbeef.npy"
    _seed_array(tmp_path, key, _synthetic_array(200))
    r = client.post("/pipeline/lidar-points", headers=GOOD_BEARER, json=_body(key))
    assert r.status_code == 200, r.text
    body = r.json()
    assert not list(_validator("LidarPointsResponse").iter_errors(body))
    assert body["point_count"] == 200
    assert body["returned_count"] == 200
    assert len(body["points"]) == 200


def test_endpoint_honors_max_points(client, tmp_path):
    key = "cache/lidar/cap.npy"
    _seed_array(tmp_path, key, _synthetic_array(1000))
    r = client.post("/pipeline/lidar-points", headers=GOOD_BEARER, json=_body(key, max_points=100))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["point_count"] == 1000
    assert body["returned_count"] == 100


def test_endpoint_404_on_missing_array(client):
    r = client.post(
        "/pipeline/lidar-points", headers=GOOD_BEARER, json=_body("cache/lidar/nope.npy")
    )
    assert r.status_code == 404, r.text


def test_endpoint_requires_bearer(client):
    r = client.post("/pipeline/lidar-points", json=_body("cache/lidar/x.npy"))
    assert r.status_code == 401


def test_endpoint_rejects_schema_major_mismatch(client, tmp_path):
    key = "cache/lidar/v.npy"
    _seed_array(tmp_path, key, _synthetic_array(10))
    body = _body(key)
    body["pipelineSchemaVersion"] = "9.0.0"
    r = client.post("/pipeline/lidar-points", headers=GOOD_BEARER, json=body)
    assert r.status_code == 409, r.text
