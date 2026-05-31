"""LiDAR ingest tests.

Exercise the ingest plumbing WITHOUT PDAL/GDAL or network: a `FixtureWesmIndex`
supplies coverage and a `FixtureCropper` returns a synthetic class-6 point cloud
in the work unit's native CRS. This covers hops 1 (coverage / fast-fail), 3
(classification filter), 4 (CRS reprojection to local UTM), 5 (caching), and the
contract mapping. The real COPC read (hop 2) is the only thing stubbed; it's
exercised separately on the live path (LIDAR_LIVE=1) and in the compose smoke.
"""

from __future__ import annotations

import io
import json
import time
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient
from jsonschema import Draft202012Validator

from app.lidar import router as lidar_router
from app.lidar.ingest import ASPRS_BUILDING_CLASS, CroppedCloud, Cropper, ingest_lidar
from app.lidar.wesm import FixtureWesmIndex, WorkUnit

REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA = json.loads((REPO_ROOT / "shared" / "pipeline_schema.json").read_text())
FIXTURE_DIR = Path(__file__).resolve().parent / "fixtures" / "f06"
GOOD_BEARER = {"Authorization": "Bearer test-shared-secret"}


def _validator(entity: str) -> Draft202012Validator:
    return Draft202012Validator({"$ref": f"#/$defs/{entity}", "$defs": SCHEMA["$defs"]})


# A small Lincoln, NE building footprint (covered by NE_Lancaster_2020, UTM 14N).
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
    "source": "imagery",
    "confidence": 0.88,
}

# A rural-Wyoming footprint with no work-unit coverage in the fixture index.
WYOMING_GAP_BUILDING = {
    "type": "Polygon",
    "coordinates": [
        [
            [-107.5, 43.0],
            [-107.4995, 43.0],
            [-107.4995, 43.0004],
            [-107.5, 43.0004],
            [-107.5, 43.0],
        ]
    ],
    "source": "imagery",
    "confidence": 0.5,
}


def _fixture_index() -> FixtureWesmIndex:
    return FixtureWesmIndex.from_json(FIXTURE_DIR / "wesm_index.json")


class FixtureCropper(Cropper):
    """Returns a synthetic point cloud in the work unit's native CRS.

    The cloud is a small grid of class-6 (building) points plus a few non-building
    (class 2 ground / class 1 unassigned) points to prove the classification
    filter drops them. Points are generated in the WGS84 ring's local UTM and then
    LABELLED as being in `work_unit.epsg`, so the ingest reprojection step is a
    genuine transform when those differ.
    """

    def __init__(self, n_building: int = 200, contaminate: bool = True):
        self.n_building = n_building
        self.contaminate = contaminate

    def crop(self, work_unit: WorkUnit, building_polygon_wgs84: dict, buffer_m: float = 1.0) -> CroppedCloud:
        from shapely.geometry import shape

        from app.lidar import crs

        poly = shape(building_polygon_wgs84)
        c = poly.centroid
        local_utm = crs.utm_epsg_for(c.x, c.y)
        # Generate a grid in the building's local UTM, then express it in the work
        # unit's native CRS (so ingest's reproject native->local is meaningful).
        t_to_native = crs.transformer(local_utm, work_unit.epsg)
        ring_utm = crs.reproject_ring(building_polygon_wgs84["coordinates"][0], 4326, local_utm)
        xs = [p[0] for p in ring_utm]
        ys = [p[1] for p in ring_utm]
        gx = np.linspace(min(xs), max(xs), int(self.n_building**0.5))
        gy = np.linspace(min(ys), max(ys), int(self.n_building**0.5))
        pts = []
        for x in gx:
            for y in gy:
                nx, ny = t_to_native.transform(x, y)
                pts.append([nx, ny, 100.0, ASPRS_BUILDING_CLASS])
        if self.contaminate:
            # ground + unassigned points that must be filtered out.
            for x in gx[:3]:
                nx, ny = t_to_native.transform(x, min(ys) - 5)
                pts.append([nx, ny, 95.0, 2.0])
                pts.append([nx, ny, 95.0, 1.0])
        return CroppedCloud(points=np.array(pts, dtype=np.float64), src_epsg=work_unit.epsg)


class EmptyCropper(Cropper):
    def crop(self, work_unit, building_polygon_wgs84, buffer_m=1.0):
        # All non-building points -> ingest should report no_building_points.
        return CroppedCloud(points=np.array([[0.0, 0.0, 0.0, 2.0]]), src_epsg=work_unit.epsg)


def _mem_put():
    store: dict[str, bytes] = {}

    def put_bytes(key: str, data: bytes) -> str:
        store[key] = data
        return key

    return put_bytes, store


# --------------------------------------------------------------------------- #
# Core ingest logic                                                           #
# --------------------------------------------------------------------------- #


def test_coverage_hit_returns_available_with_points():
    put_bytes, store = _mem_put()
    outcome = ingest_lidar(LINCOLN_BUILDING, index=_fixture_index(), cropper=FixtureCropper(), put_bytes=put_bytes)
    assert outcome.status == "LIDAR_AVAILABLE"
    assert outcome.point_count and outcome.point_count > 100
    assert outcome.point_array_ref in store
    assert outcome.point_array_ref.startswith("cache/lidar/")
    assert outcome.work_unit and outcome.work_unit.name == "NE_Lancaster_2020"


def test_gap_returns_missing_fast():
    put_bytes, _ = _mem_put()
    start = time.monotonic()
    outcome = ingest_lidar(
        WYOMING_GAP_BUILDING, index=_fixture_index(), cropper=FixtureCropper(), put_bytes=put_bytes
    )
    elapsed = time.monotonic() - start
    assert outcome.status == "LIDAR_MISSING"
    assert outcome.reason == "no_coverage"
    assert elapsed < 2.0, f"gap check took {elapsed:.2f}s, must be <2s (no fetch attempted)"


def test_crs_output_is_building_local_utm():
    # Lincoln NE -> EPSG:32614 (UTM zone 14N). The cached array's coords must be
    # in that zone's metric range (easting ~ 6-7e5, northing ~ 4.5e6).
    from app.lidar import crs

    assert crs.utm_epsg_for(-96.7024, 40.8137) == 32614
    put_bytes, store = _mem_put()
    outcome = ingest_lidar(LINCOLN_BUILDING, index=_fixture_index(), cropper=FixtureCropper(), put_bytes=put_bytes)
    assert outcome.utm_zone == 32614
    arr = np.load(io.BytesIO(store[outcome.point_array_ref]))
    assert 1e5 < arr[:, 0].mean() < 9e5
    assert 4.4e6 < arr[:, 1].mean() < 4.6e6


def test_classification_filter_drops_non_building_points():
    put_bytes, store = _mem_put()
    outcome = ingest_lidar(
        LINCOLN_BUILDING, index=_fixture_index(), cropper=FixtureCropper(contaminate=True), put_bytes=put_bytes
    )
    arr = np.load(io.BytesIO(store[outcome.point_array_ref]))
    # Only class-6 survives.
    assert np.all(arr[:, 3] == ASPRS_BUILDING_CLASS)


def test_no_building_points_returns_missing():
    put_bytes, _ = _mem_put()
    outcome = ingest_lidar(LINCOLN_BUILDING, index=_fixture_index(), cropper=EmptyCropper(), put_bytes=put_bytes)
    assert outcome.status == "LIDAR_MISSING"
    assert outcome.reason == "no_building_points"


def test_stale_lidar_warning_for_old_work_unit():
    # A Chicago building hits IL_Cook_2017_stale (2017, >5y before 2026).
    chicago = {
        "type": "Polygon",
        "coordinates": [
            [[-87.65, 41.88], [-87.6496, 41.88], [-87.6496, 41.8803], [-87.65, 41.8803], [-87.65, 41.88]]
        ],
        "source": "imagery",
        "confidence": 0.8,
    }
    put_bytes, _ = _mem_put()
    outcome = ingest_lidar(chicago, index=_fixture_index(), cropper=FixtureCropper(), put_bytes=put_bytes)
    assert outcome.status == "LIDAR_AVAILABLE"
    assert "stale_lidar" in (outcome.warnings or [])


def test_cache_key_is_deterministic_for_same_polygon():
    put_bytes, _ = _mem_put()
    o1 = ingest_lidar(LINCOLN_BUILDING, index=_fixture_index(), cropper=FixtureCropper(), put_bytes=put_bytes)
    o2 = ingest_lidar(LINCOLN_BUILDING, index=_fixture_index(), cropper=FixtureCropper(), put_bytes=put_bytes)
    assert o1.point_array_ref == o2.point_array_ref


# --------------------------------------------------------------------------- #
# Endpoint + contract                                                         #
# --------------------------------------------------------------------------- #


@pytest.fixture
def client(monkeypatch, tmp_path):
    monkeypatch.setattr(lidar_router, "_resolve_index", _fixture_index)
    monkeypatch.setattr(lidar_router, "_resolve_cropper", lambda: FixtureCropper())
    # The endpoint writes the cropped array through the real storage helper;
    # point it at a temp dir so no live Spaces is needed.
    monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
    from app.main import app

    return TestClient(app)


def _request_body(building: dict) -> dict:
    return {"pipelineSchemaVersion": "0.2.0", "building_polygon": building, "parcel_polygon": None}


def test_endpoint_available_validates_against_schema(client):
    r = client.post("/pipeline/ingest-lidar", headers=GOOD_BEARER, json=_request_body(LINCOLN_BUILDING))
    assert r.status_code == 200, r.text
    body = r.json()
    assert not list(_validator("IngestLidarResponse").iter_errors(body))
    assert body["lidar"]["status"] == "LIDAR_AVAILABLE"
    assert body["utm_zone"] == 32614


def test_endpoint_missing_validates_against_schema(client):
    r = client.post("/pipeline/ingest-lidar", headers=GOOD_BEARER, json=_request_body(WYOMING_GAP_BUILDING))
    assert r.status_code == 200, r.text
    body = r.json()
    assert not list(_validator("IngestLidarResponse").iter_errors(body))
    assert body["lidar"]["status"] == "LIDAR_MISSING"
    assert body["utm_zone"] is None


def test_endpoint_requires_bearer(client):
    r = client.post("/pipeline/ingest-lidar", json=_request_body(LINCOLN_BUILDING))
    assert r.status_code == 401


def test_endpoint_rejects_schema_major_mismatch(client):
    body = _request_body(LINCOLN_BUILDING)
    body["pipelineSchemaVersion"] = "9.0.0"
    r = client.post("/pipeline/ingest-lidar", headers=GOOD_BEARER, json=body)
    assert r.status_code == 409, r.text
