"""Test sidecar /skeleton and /health.

Per the F-01 feature spec, the *cross-language* IPC test lives on the Rails
side and uses a real running sidecar (subprocess). This file is the
sidecar-side unit-level coverage: the auth guard rejects bad/missing tokens
and the happy path round-trips a payload.
"""

from fastapi.testclient import TestClient

from app.main import SIDECAR_VERSION, app

GOOD_BEARER = {"Authorization": "Bearer test-shared-secret"}
BAD_BEARER = {"Authorization": "Bearer wrong"}

client = TestClient(app)


def test_health_returns_ok():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "sidecar_version": SIDECAR_VERSION}


def test_skeleton_happy_path():
    response = client.post(
        "/skeleton",
        headers=GOOD_BEARER,
        json={"job_id": "abc-123", "sent_at": "2026-05-27T20:00:00Z"},
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["job_id"] == "abc-123"
    assert body["echo_payload"] == "hello from sidecar"
    assert body["sidecar_version"] == SIDECAR_VERSION
    assert body["received_at"]  # ISO-formatted timestamp present


def test_skeleton_rejects_missing_bearer():
    response = client.post(
        "/skeleton",
        json={"job_id": "abc-123", "sent_at": "2026-05-27T20:00:00Z"},
    )
    assert response.status_code == 401


def test_skeleton_rejects_wrong_bearer():
    response = client.post(
        "/skeleton",
        headers=BAD_BEARER,
        json={"job_id": "abc-123", "sent_at": "2026-05-27T20:00:00Z"},
    )
    assert response.status_code == 401


def test_skeleton_rejects_malformed_authorization_header():
    response = client.post(
        "/skeleton",
        headers={"Authorization": "test-shared-secret"},  # no "Bearer " prefix
        json={"job_id": "abc-123", "sent_at": "2026-05-27T20:00:00Z"},
    )
    assert response.status_code == 401
