"""Shared-secret bearer auth between Rails and the sidecar (ADR-008)."""

from __future__ import annotations

import hmac
import os

from fastapi import Header, HTTPException, status


def _expected_secret() -> str:
    secret = os.environ.get("SIDECAR_SHARED_SECRET", "")
    if not secret:
        raise RuntimeError(
            "SIDECAR_SHARED_SECRET is unset; refusing to start. "
            "Set it in the environment (Kamal injects from .kamal/secrets in prod)."
        )
    return secret


def require_bearer(authorization: str | None = Header(default=None)) -> None:
    expected = _expected_secret()
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
