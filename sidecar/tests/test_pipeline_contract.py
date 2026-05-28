"""Python half of the F-02 contract test.

Validates every fixture in `spec/fixtures/pipeline/` (the SAME corpus the Ruby
contract spec uses) two ways:

1. against `shared/pipeline_schema.json` via the `jsonschema` library (the JSON
   Schema source of truth), and
2. against the Pydantic models in `sidecar/contracts/pipeline.py`.

If the Pydantic models drift from the JSON Schema, or either drifts from what
Ruby accepts, one of the suites goes red. The endpoint round-trip itself is
covered end-to-end on the Rails side (real-sidecar request spec) per the F-01
testing pattern; here we add sidecar-local coverage of the new endpoint.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from jsonschema import Draft202012Validator
from pydantic import ValidationError

from app.main import app
from contracts.pipeline import ENTITY_MODELS

# repo root = sidecar/tests -> sidecar -> repo
REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = REPO_ROOT / "shared" / "pipeline_schema.json"
FIXTURE_DIR = REPO_ROOT / "spec" / "fixtures" / "pipeline"

GOOD_BEARER = {"Authorization": "Bearer test-shared-secret"}

_SCHEMA = json.loads(SCHEMA_PATH.read_text())
_FIXTURES = sorted(FIXTURE_DIR.glob("*.json"))


def _validator_for(entity: str) -> Draft202012Validator:
    # Root a validator at the named $def, supplying the whole doc so $refs resolve.
    sub = {"$ref": f"#/$defs/{entity}", "$defs": _SCHEMA["$defs"]}
    return Draft202012Validator(sub)


def test_schema_version_is_pinned():
    assert _SCHEMA["pipelineSchemaVersion"] == "0.3.0"


def test_fixture_corpus_is_nonempty():
    assert _FIXTURES, f"no fixtures found in {FIXTURE_DIR}"


@pytest.mark.parametrize("path", _FIXTURES, ids=lambda p: p.name)
def test_fixture_matches_json_schema(path: Path):
    fixture = json.loads(path.read_text())
    entity, expected_valid, payload = (
        fixture["entity"],
        fixture["valid"],
        fixture["payload"],
    )
    errors = list(_validator_for(entity).iter_errors(payload))
    if expected_valid:
        assert not errors, f"{path.name}: expected valid, got {[e.message for e in errors]}"
    else:
        assert errors, f"{path.name}: expected schema rejection, but it validated"


@pytest.mark.parametrize("path", _FIXTURES, ids=lambda p: p.name)
def test_fixture_matches_pydantic_model(path: Path):
    fixture = json.loads(path.read_text())
    entity, expected_valid, payload = (
        fixture["entity"],
        fixture["valid"],
        fixture["payload"],
    )
    model = ENTITY_MODELS[entity]
    if expected_valid:
        model.model_validate(payload)  # raises on failure -> test fails
    else:
        with pytest.raises(ValidationError):
            model.model_validate(payload)


client = TestClient(app)


def test_run_validate_round_trips_a_request():
    request_fixture = json.loads((FIXTURE_DIR / "pipeline_request.valid.json").read_text())
    response = client.post(
        "/pipeline/run-validate",
        headers=GOOD_BEARER,
        json=request_fixture["payload"],
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["pipelineSchemaVersion"] == "0.3.0"
    assert body["job_id"] == request_fixture["payload"]["job"]["job_id"]
    assert body["status"] == "OK"
    # The echoed response itself validates against the PipelineResponse schema.
    assert not list(_validator_for("PipelineResponse").iter_errors(body))


def test_run_validate_rejects_malformed_request():
    response = client.post(
        "/pipeline/run-validate",
        headers=GOOD_BEARER,
        json={"pipelineSchemaVersion": "0.1.0", "job": {"job_id": "x"}},  # missing address
    )
    assert response.status_code == 422, response.text


def test_run_validate_rejects_schema_major_mismatch():
    response = client.post(
        "/pipeline/run-validate",
        headers=GOOD_BEARER,
        json={
            "pipelineSchemaVersion": "9.0.0",
            "job": {
                "job_id": "11111111-1111-4111-8111-111111111111",
                "address": {"raw": "123 Main St"},
            },
        },
    )
    assert response.status_code == 409, response.text


def test_run_validate_rejects_empty_schema_version():
    # An empty pipelineSchemaVersion must not slip past the major-version check.
    response = client.post(
        "/pipeline/run-validate",
        headers=GOOD_BEARER,
        json={
            "pipelineSchemaVersion": "",
            "job": {
                "job_id": "11111111-1111-4111-8111-111111111111",
                "address": {"raw": "123 Main St"},
            },
        },
    )
    assert response.status_code == 422, response.text


def test_run_validate_requires_bearer():
    response = client.post("/pipeline/run-validate", json={})
    assert response.status_code == 401
