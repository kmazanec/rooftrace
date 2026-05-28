"""Shared-secret bearer auth between Rails and the sidecar (ADR-008)."""

from __future__ import annotations

import hmac
import os

from fastapi import Header, HTTPException, status

# Validate the shared secret ONCE at import time so the process refuses to
# start when it's unset, rather than failing every request with a 500 (and
# leaking the secret name into per-request tracebacks). The compose files also
# guard this with ${SIDECAR_SHARED_SECRET:?...}; this is the in-app backstop.
_EXPECTED_SECRET = os.environ.get("SIDECAR_SHARED_SECRET", "")
if not _EXPECTED_SECRET:
    raise RuntimeError(
        "SIDECAR_SHARED_SECRET is unset; refusing to start. "
        "Set it in the environment (compose injects it from ops/.env.production in prod)."
    )


def require_bearer(authorization: str | None = Header(default=None)) -> None:
    expected = _EXPECTED_SECRET
    prefix = "Bearer "
    if not authorization or not authorization.startswith(prefix):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing or malformed Authorization header",
        )
    token = authorization[len(prefix) :]
    if not hmac.compare_digest(token, expected):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid sidecar bearer token",
        )
