"""POST /pipeline/fuse-capture endpoint tests (ADR-007 capture fusion).

Local-root storage (STORAGE_LOCAL_ROOT) with the committed f16 fixtures placed
at the keys the router resolves: uploads/<job>/session.json, the capture mesh
ref, and the LiDAR point_array_ref. No network / Spaces.
"""

from __future__ import annotations

import io
import json
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "f16"
GOOD_BEARER = {"Authorization": "Bearer test-shared-secret"}

JOB_ID = "11111111-1111-4111-8111-111111111111"
MESH_KEY = f"uploads/{JOB_ID}/arkit_mesh.obj"
SESSION_KEY = f"uploads/{JOB_ID}/session.json"
LIDAR_KEY = f"cache/{JOB_ID}/points.npy"


@pytest.fixture(scope="module")
def client():
    from app.main import app

    return TestClient(app)


def _write(root: Path, key: str, data: bytes) -> None:
    full = root / key
    full.parent.mkdir(parents=True, exist_ok=True)
    full.write_bytes(data)


def _seed_storage(root: Path, mesh_name: str = "arkit_mesh.obj") -> None:
    session = {
        "manifest_version": "1.0.0",
        "session_id": "5e551011-0000-4000-8000-000000000001",
        "job_id": JOB_ID,
        "gps_origin": {
            "latitude": 40.808,
            "longitude": -96.706,
            "altitude_m": 360.0,
            "horizontal_accuracy_m": 3.5,
            "vertical_accuracy_m": 5.0,
        },
    }
    _write(root, SESSION_KEY, json.dumps(session).encode())
    _write(root, MESH_KEY, (FIXTURES / mesh_name).read_bytes())

    buf = io.BytesIO()
    np.save(buf, np.load(FIXTURES / "lidar_cloud.npy"))
    _write(root, LIDAR_KEY, buf.getvalue())


def _request_body():
    return {
        "pipelineSchemaVersion": "0.3.0",
        "job_id": JOB_ID,
        "capture_mesh_ref": MESH_KEY,
        "lidar": {
            "status": "LIDAR_AVAILABLE",
            "point_array_ref": LIDAR_KEY,
            "point_count": 500,
            "source": "lidar",
            "confidence": 0.95,
        },
    }


class TestFuseCaptureEndpoint:
    def test_happy_path(self, client, tmp_path, monkeypatch):
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        _seed_storage(tmp_path)

        resp = client.post("/pipeline/fuse-capture", headers=GOOD_BEARER, json=_request_body())
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["measurement"] is not None
        assert body["measurement"]["source"] == "fusion"
        assert body["measurement"]["features"] == []
        assert body["icp_rmse_m"] < 0.15, body["icp_rmse_m"]

    def test_happy_path_returns_solved_transform(self, client, tmp_path, monkeypatch):
        """On convergence the solved ARKit->UTM transform + its UTM EPSG are
        returned (a row-major 16-float 4x4) so the photo-projection stage reuses
        them instead of re-solving. The acceptance fixture is a near-pure
        translation, so the rotation block reads ~identity."""
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        _seed_storage(tmp_path)

        resp = client.post("/pipeline/fuse-capture", headers=GOOD_BEARER, json=_request_body())
        assert resp.status_code == 200, resp.text
        body = resp.json()

        transform = body["arkit_to_utm"]
        assert isinstance(transform, list) and len(transform) == 16, transform
        # UTM EPSG derived from the GPS-origin longitude (-96.706 -> zone 14N).
        assert body["utm_epsg"] == 32614, body["utm_epsg"]
        # Bottom row of a rigid 4x4 is [0,0,0,1].
        assert transform[12:16] == [0.0, 0.0, 0.0, 1.0]
        # Near-pure translation: the 3x3 rotation block is ~identity.
        rot = [transform[0], transform[1], transform[2],
               transform[4], transform[5], transform[6],
               transform[8], transform[9], transform[10]]
        assert abs(rot[0] - 1.0) < 0.05 and abs(rot[4] - 1.0) < 0.05 and abs(rot[8] - 1.0) < 0.05

    def test_bad_alignment_returns_null_measurement(self, client, tmp_path, monkeypatch):
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        _seed_storage(tmp_path, mesh_name="arkit_mesh_bad.obj")

        resp = client.post("/pipeline/fuse-capture", headers=GOOD_BEARER, json=_request_body())
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["measurement"] is None
        assert body["icp_rmse_m"] > 0.5, body["icp_rmse_m"]
        # On non-convergence no solved transform is returned (response_model has
        # arkit_to_utm/utm_epsg optional; the router omits them).
        assert body.get("arkit_to_utm") is None
        assert body.get("utm_epsg") is None

    def test_missing_capture_mesh_ref_returns_422(self, client, tmp_path, monkeypatch):
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        _seed_storage(tmp_path)
        body = _request_body()
        body["capture_mesh_ref"] = f"uploads/{JOB_ID}/nonexistent.obj"

        resp = client.post("/pipeline/fuse-capture", headers=GOOD_BEARER, json=body)
        assert resp.status_code == 422, resp.text

    def test_version_mismatch_returns_409(self, client, tmp_path, monkeypatch):
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        _seed_storage(tmp_path)
        body = _request_body()
        body["pipelineSchemaVersion"] = "9.0.0"

        resp = client.post("/pipeline/fuse-capture", headers=GOOD_BEARER, json=body)
        assert resp.status_code == 409, resp.text

    def test_no_bearer_returns_401(self, client, tmp_path, monkeypatch):
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        resp = client.post("/pipeline/fuse-capture", json=_request_body())
        assert resp.status_code == 401, resp.text

    def test_pickle_npy_returns_422(self, client, tmp_path, monkeypatch):
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        _seed_storage(tmp_path)
        # A pickled-object .npy (allow_pickle would be an RCE vector). np.load
        # with allow_pickle=False must reject it as a 422, not execute it.
        buf = io.BytesIO()
        np.save(buf, np.array([{"evil": "payload"}], dtype=object), allow_pickle=True)
        _write(tmp_path, LIDAR_KEY, buf.getvalue())

        resp = client.post("/pipeline/fuse-capture", headers=GOOD_BEARER, json=_request_body())
        assert resp.status_code == 422, resp.text

    def test_nonnumeric_longitude_returns_422(self, client, tmp_path, monkeypatch):
        # A non-numeric GPS longitude must be a deterministic 422, not an
        # unhandled ValueError/pyproj 500 + retry loop.
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        _seed_storage(tmp_path)
        session = json.loads((tmp_path / SESSION_KEY).read_text())
        session["gps_origin"]["longitude"] = "west"
        _write(tmp_path, SESSION_KEY, json.dumps(session).encode())

        resp = client.post("/pipeline/fuse-capture", headers=GOOD_BEARER, json=_request_body())
        assert resp.status_code == 422, resp.text

    def test_nan_longitude_returns_422(self, client, tmp_path, monkeypatch):
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        _seed_storage(tmp_path)
        session = json.loads((tmp_path / SESSION_KEY).read_text())
        # "NaN" -> float('nan') -> rejected by math.isfinite.
        session["gps_origin"]["longitude"] = "NaN"
        _write(tmp_path, SESSION_KEY, json.dumps(session).encode())

        resp = client.post("/pipeline/fuse-capture", headers=GOOD_BEARER, json=_request_body())
        assert resp.status_code == 422, resp.text

    def test_out_of_range_latitude_returns_422(self, client, tmp_path, monkeypatch):
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        _seed_storage(tmp_path)
        session = json.loads((tmp_path / SESSION_KEY).read_text())
        session["gps_origin"]["latitude"] = 999.0
        _write(tmp_path, SESSION_KEY, json.dumps(session).encode())

        resp = client.post("/pipeline/fuse-capture", headers=GOOD_BEARER, json=_request_body())
        assert resp.status_code == 422, resp.text

    def test_empty_lidar_array_returns_422(self, client, tmp_path, monkeypatch):
        # Too few points to align: a deterministic 422, not an Open3D native 500.
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        _seed_storage(tmp_path)
        buf = io.BytesIO()
        np.save(buf, np.zeros((0, 3), dtype=np.float64))
        _write(tmp_path, LIDAR_KEY, buf.getvalue())

        resp = client.post("/pipeline/fuse-capture", headers=GOOD_BEARER, json=_request_body())
        assert resp.status_code == 422, resp.text

    def test_nan_bearing_lidar_array_returns_422(self, client, tmp_path, monkeypatch):
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        _seed_storage(tmp_path)
        pts = np.ones((200, 3), dtype=np.float64)
        pts[0, 0] = np.nan
        buf = io.BytesIO()
        np.save(buf, pts)
        _write(tmp_path, LIDAR_KEY, buf.getvalue())

        resp = client.post("/pipeline/fuse-capture", headers=GOOD_BEARER, json=_request_body())
        assert resp.status_code == 422, resp.text
