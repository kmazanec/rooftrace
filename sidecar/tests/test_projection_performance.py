"""Performance budget for photo projection (ADR-019 acceptance criterion):
projecting 8 photos completes well within 30 seconds.

Hermetic: a small synthetic photo + a faces-bearing world mesh in a tmp local
root, the live render path enabled. The per-photo work (image decode, facet
projection, ray-cast occlusion, SVG + composite, two put_bytes) is the same the
production stage does; this pins that 8 of them stay inside the budget.
"""

from __future__ import annotations

import io
import time

from fastapi.testclient import TestClient
from PIL import Image

from app.main import app

GOOD_BEARER = {"Authorization": "Bearer test-shared-secret"}
JOB_ID = "11111111-1111-4111-8111-111111111111"
_UTM_EPSG = 32614
_ANCHOR_E = 500000.0
_ANCHOR_N = 4494354.8

client = TestClient(app)


def _body(seq: int):
    return {
        "pipelineSchemaVersion": "0.4.0",
        "job_id": JOB_ID,
        "photo_ref": f"uploads/{JOB_ID}/photo_{seq:02d}.jpg",
        "world_mesh_ref": f"uploads/{JOB_ID}/arkit_mesh.obj",
        "arkit_to_utm": [
            1.0, 0.0, 0.0, _ANCHOR_E,
            0.0, 1.0, 0.0, _ANCHOR_N,
            0.0, 0.0, 1.0, 0.0,
            0.0, 0.0, 0.0, 1.0,
        ],
        "utm_epsg": _UTM_EPSG,
        "pose_confidence": 0.9,
        "camera_pose": {
            "intrinsics": [1000.0, 0.0, 512.0, 0.0, 1000.0, 384.0, 0.0, 0.0, 1.0],
            "extrinsics": [
                1.0, 0.0, 0.0, 0.0,
                0.0, 1.0, 0.0, 0.0,
                0.0, 0.0, 1.0, 0.0,
                0.0, 0.0, 0.0, 1.0,
            ],
        },
        "facets": [
            {
                "facet_id": "F1",
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
        ],
        "features": [],
    }


def test_eight_photos_under_30s(tmp_path, monkeypatch):
    monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
    monkeypatch.delenv("PROJECT_PHOTO_FIXTURE", raising=False)  # real render is the default

    # Seed 8 photos + one world mesh (a small two-triangle wall).
    img = Image.new("RGB", (640, 480), (100, 120, 140))
    buf = io.BytesIO()
    img.save(buf, format="JPEG")
    for seq in range(8):
        p = tmp_path / f"uploads/{JOB_ID}/photo_{seq:02d}.jpg"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(buf.getvalue())
    mesh = tmp_path / f"uploads/{JOB_ID}/arkit_mesh.obj"
    mesh.write_text("v -50 -50 20\nv 50 -50 20\nv 50 50 20\nv -50 50 20\nf 1 2 3\nf 1 3 4\n")

    start = time.monotonic()
    for seq in range(8):
        r = client.post("/pipeline/project-photo", headers=GOOD_BEARER, json=_body(seq))
        assert r.status_code == 200, r.text
    elapsed = time.monotonic() - start
    assert elapsed < 30.0, f"8-photo projection took {elapsed:.1f}s (budget 30s)"
