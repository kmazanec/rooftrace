"""Tests: POST /pipeline/project-photo (the photo-overlay endpoint, ADR-019).

Hermetic: STORAGE_LOCAL_ROOT (tmp) holds the source photo + optional world mesh;
put_bytes writes the projected artifacts back. Coverage is the CONTRACT plus the
live render path (PROJECT_PHOTO_LIVE=1): a real composite PNG at the source
resolution + a real SVG overlay under artifacts/<job>/projected/, and the
behind-wall occlusion surfacing in occluded_facet_ids.
"""

from __future__ import annotations

import io
from pathlib import Path

from fastapi.testclient import TestClient
from PIL import Image

from app.main import app
from contracts.pipeline import PIPELINE_SCHEMA_VERSION, ProjectPhotoResponse

GOOD_BEARER = {"Authorization": "Bearer test-shared-secret"}
BAD_BEARER = {"Authorization": "Bearer wrong-secret"}

JOB_ID = "11111111-1111-4111-8111-111111111111"
PHOTO_KEY = f"uploads/{JOB_ID}/photo_03.jpg"
MESH_KEY = f"uploads/{JOB_ID}/arkit_mesh.obj"

client = TestClient(app)


# A pure-translation arkit_to_utm: ARKit origin at a UTM 14N anchor. A WGS84
# facet near that anchor's lon/lat lands a few metres from the ARKit origin.
# Anchor chosen so the facet's WGS84 vertices (~ -99.0, 40.6) bridge to within a
# few metres of the ARKit origin (the facet UTM is ~ (500000, 4494354.8)).
_UTM_EPSG = 32614
_ANCHOR_E = 500000.0
_ANCHOR_N = 4494354.8


def _arkit_to_utm():
    return [
        1.0, 0.0, 0.0, _ANCHOR_E,
        0.0, 1.0, 0.0, _ANCHOR_N,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    ]


def _facet(facet_id="F1"):
    # A WGS84 quad near the anchor (so it sits within metres of the ARKit origin).
    return {
        "facet_id": facet_id,
        "vertices": [
            [-99.0, 40.6, 4.0],
            [-98.99995, 40.6, 4.0],
            [-98.99995, 40.60005, 4.0],
            [-99.0, 40.60005, 4.0],
        ],
        "pitch_ratio": 6.0,
        "pitch_degrees": 26.57,
        "area_sq_ft": 800.0,
        "source": "fusion",
        "confidence": 0.9,
    }


def _camera_pose():
    # Camera at ARKit origin looking down +Z toward the facet, 1024x768 intrinsics.
    return {
        "intrinsics": [1000.0, 0.0, 512.0, 0.0, 1000.0, 384.0, 0.0, 0.0, 1.0],
        "extrinsics": [
            1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            0.0, 0.0, 0.0, 1.0,
        ],
    }


def _good_body(**overrides):
    body = {
        "pipelineSchemaVersion": PIPELINE_SCHEMA_VERSION,
        "job_id": JOB_ID,
        "photo_ref": PHOTO_KEY,
        "arkit_to_utm": _arkit_to_utm(),
        "utm_epsg": _UTM_EPSG,
        "pose_confidence": 0.9,
        "camera_pose": _camera_pose(),
        "facets": [_facet()],
        "features": [],
    }
    body.update(overrides)
    return body


def _seed_photo(root: Path, w=320, h=240):
    img = Image.new("RGB", (w, h), (40, 90, 160))
    buf = io.BytesIO()
    img.save(buf, format="JPEG")
    full = root / PHOTO_KEY
    full.parent.mkdir(parents=True, exist_ok=True)
    full.write_bytes(buf.getvalue())


def _seed_mesh(root: Path, obj_text: str):
    full = root / MESH_KEY
    full.parent.mkdir(parents=True, exist_ok=True)
    full.write_text(obj_text)


class TestContract:
    def test_requires_bearer(self):
        assert client.post("/pipeline/project-photo", json=_good_body()).status_code == 401

    def test_rejects_wrong_bearer(self):
        r = client.post("/pipeline/project-photo", headers=BAD_BEARER, json=_good_body())
        assert r.status_code == 401

    def test_rejects_wrong_major_version(self):
        body = _good_body()
        body["pipelineSchemaVersion"] = "9.0.0"
        r = client.post("/pipeline/project-photo", headers=GOOD_BEARER, json=body)
        assert r.status_code == 409, r.text

    def test_rejects_missing_transform(self):
        # No arkit_to_utm/utm_epsg -> can't place facets -> 422.
        body = _good_body()
        del body["arkit_to_utm"]
        del body["utm_epsg"]
        r = client.post("/pipeline/project-photo", headers=GOOD_BEARER, json=body)
        assert r.status_code == 422, r.text

    def test_placeholder_path_returns_valid_response(self):
        # Default (no PROJECT_PHOTO_LIVE): the hermetic placeholder still writes
        # the artifacts and returns a valid, schema-shaped response.
        r = client.post("/pipeline/project-photo", headers=GOOD_BEARER, json=_good_body())
        assert r.status_code == 200, r.text
        body = r.json()
        ProjectPhotoResponse.model_validate(body)
        assert body["composite_ref"] == f"artifacts/{JOB_ID}/projected/photo_03.png"
        assert body["overlay_svg_ref"] == f"artifacts/{JOB_ID}/projected/photo_03.svg"
        assert body["pose_confidence"] == 0.9


class TestLiveRender:
    def test_live_composite_is_source_resolution(self, tmp_path, monkeypatch):
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        monkeypatch.setenv("PROJECT_PHOTO_LIVE", "1")
        _seed_photo(tmp_path, w=320, h=240)

        r = client.post("/pipeline/project-photo", headers=GOOD_BEARER, json=_good_body())
        assert r.status_code == 200, r.text
        body = r.json()
        ProjectPhotoResponse.model_validate(body)

        composite_bytes = (tmp_path / body["composite_ref"]).read_bytes()
        img = Image.open(io.BytesIO(composite_bytes))
        assert img.size == (320, 240)
        # SVG overlay artifact written too.
        svg = (tmp_path / body["overlay_svg_ref"]).read_text()
        assert "<svg" in svg

    def test_live_occlusion_behind_wall_marks_facet_occluded(self, tmp_path, monkeypatch):
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        monkeypatch.setenv("PROJECT_PHOTO_LIVE", "1")
        _seed_photo(tmp_path)
        # A wall (two triangles) at z ~ 2 m, between the camera origin and the
        # facet (which bridges to roughly z=4 m near the anchor). Spans a wide
        # x,y so it fully covers the facet's line of sight.
        obj = (
            "v -50 -50 2\n"
            "v 50 -50 2\n"
            "v 50 50 2\n"
            "v -50 50 2\n"
            "f 1 2 3\n"
            "f 1 3 4\n"
        )
        _seed_mesh(tmp_path, obj)

        body = _good_body(world_mesh_ref=MESH_KEY)
        r = client.post("/pipeline/project-photo", headers=GOOD_BEARER, json=body)
        assert r.status_code == 200, r.text
        assert "F1" in r.json()["occluded_facet_ids"], r.json()
