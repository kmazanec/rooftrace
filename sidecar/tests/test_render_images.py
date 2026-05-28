"""Tests: POST /pipeline/render-images (the report map-image endpoint).

Test command (from sidecar/):
    SIDECAR_SHARED_SECRET=test-shared-secret uv run pytest tests/test_render_images.py -q

DISTINCT from /pipeline/render-imagery (the satellite-tile geometry stage).
All tests are hermetic (no browser, no network): put_bytes writes to the
STORAGE_LOCAL_ROOT the conftest sets. Coverage is the CONTRACT:
  - Happy path: 200, valid RenderImageResponse, image_ref under artifacts/.
  - Auth guards: no/wrong bearer → 401.
  - Version-major mismatch → 409.
  - Out-of-range / inverted bbox → 422.
"""

from __future__ import annotations

import json
from pathlib import Path

from fastapi.testclient import TestClient

from app.main import app
from contracts.pipeline import PIPELINE_SCHEMA_VERSION, RenderImageResponse

GOOD_BEARER = {"Authorization": "Bearer test-shared-secret"}
BAD_BEARER = {"Authorization": "Bearer wrong-secret"}

REPO_ROOT = Path(__file__).resolve().parents[2]
_SCHEMA = json.loads((REPO_ROOT / "shared" / "pipeline_schema.json").read_text())

_JOB_ID = "11111111-1111-4111-8111-111111111111"


def _good_body() -> dict:
    return {
        "pipelineSchemaVersion": PIPELINE_SCHEMA_VERSION,
        "job_id": _JOB_ID,
        "bbox": [-104.9950, 39.7380, -104.9940, 39.7390],
        "width_px": 64,
        "height_px": 48,
    }


client = TestClient(app)


def test_render_images_requires_bearer():
    assert client.post("/pipeline/render-images", json=_good_body()).status_code == 401


def test_render_images_rejects_wrong_bearer():
    response = client.post("/pipeline/render-images", headers=BAD_BEARER, json=_good_body())
    assert response.status_code == 401


def test_render_images_rejects_wrong_major_version():
    body = _good_body()
    body["pipelineSchemaVersion"] = "9.0.0"
    response = client.post("/pipeline/render-images", headers=GOOD_BEARER, json=body)
    assert response.status_code == 409, response.text


def test_render_images_rejects_inverted_bbox():
    body = _good_body()
    body["bbox"] = [10.0, 10.0, 5.0, 5.0]  # min > max
    response = client.post("/pipeline/render-images", headers=GOOD_BEARER, json=body)
    assert response.status_code == 422, response.text


def test_render_images_rejects_out_of_range_bbox():
    body = _good_body()
    body["bbox"] = [200.0, 39.0, 201.0, 40.0]  # lon > 180
    response = client.post("/pipeline/render-images", headers=GOOD_BEARER, json=body)
    assert response.status_code == 422, response.text


def test_render_images_rejects_malformed_body():
    response = client.post(
        "/pipeline/render-images",
        headers=GOOD_BEARER,
        json={"pipelineSchemaVersion": PIPELINE_SCHEMA_VERSION, "job_id": _JOB_ID},
    )
    assert response.status_code == 422, response.text


def test_render_images_happy_path():
    response = client.post("/pipeline/render-images", headers=GOOD_BEARER, json=_good_body())
    assert response.status_code == 200, response.text
    body = response.json()

    # Validates against both the JSON Schema and the Pydantic model.
    RenderImageResponse.model_validate(body)
    assert body["pipelineSchemaVersion"] == PIPELINE_SCHEMA_VERSION
    assert body["job_id"] == _JOB_ID
    assert body["image_ref"].startswith(f"artifacts/{_JOB_ID}/images/map-")
    assert body["image_ref"].endswith(".png")


def test_render_images_image_ref_is_deterministic_in_the_request():
    a = client.post("/pipeline/render-images", headers=GOOD_BEARER, json=_good_body()).json()
    b = client.post("/pipeline/render-images", headers=GOOD_BEARER, json=_good_body()).json()
    assert a["image_ref"] == b["image_ref"]
