"""Shared pipeline-router plumbing.

Small helpers every stage router needs but that don't belong to any one stage.
Kept here (not in `contracts.pipeline`) so the contract module stays a pure data
contract with no FastAPI dependency.
"""

from __future__ import annotations

from fastapi import HTTPException, status

from contracts.pipeline import PIPELINE_SCHEMA_VERSION


def schema_major(version: str) -> str:
    """Major component of a `MAJOR.MINOR.PATCH` pipeline schema version."""
    return version.split(".", 1)[0]


def check_pipeline_version(req_version: str) -> None:
    """Raise 409 if the request's schema major doesn't match the sidecar's.

    The pipeline contract (ADR-008) is versioned; a major-version mismatch means
    the Rails caller and this sidecar disagree on the wire shape, so we refuse
    rather than risk silently misreading the payload.
    """
    if schema_major(req_version) != schema_major(PIPELINE_SCHEMA_VERSION):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"pipeline schema major mismatch: request {req_version} "
                f"vs sidecar {PIPELINE_SCHEMA_VERSION}"
            ),
        )
