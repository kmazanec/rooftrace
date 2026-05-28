"""RoofTrace Python sidecar — FastAPI app.

F-01 ships a stub `/skeleton` endpoint that echoes a payload with timestamps,
proving the Rails→sidecar IPC works end-to-end. The pipeline contract
(/pipeline/run-validate) lands in F-02; the real geospatial endpoints
(/pipeline/run, /pipeline/fuse-capture, /pipeline/render-images) land in
F-05 through F-16."""

from __future__ import annotations

from datetime import datetime, timezone

from fastapi import Depends, FastAPI, HTTPException, status
from pydantic import BaseModel, Field

from contracts.pipeline import (
    PIPELINE_SCHEMA_VERSION,
    GeometrySource,
    Measurement,
    PipelineRequest,
    PipelineResponse,
    PipelineStatus,
)

from .auth import require_bearer

SIDECAR_VERSION = "0.1.0"

app = FastAPI(title="rooftrace-sidecar", version=SIDECAR_VERSION)


def _schema_major(version: str) -> str:
    return version.split(".", 1)[0]


class SkeletonRequest(BaseModel):
    job_id: str = Field(..., description="UUID from Rails identifying the round-trip")
    sent_at: datetime = Field(..., description="Rails-side timestamp when the request was sent")


class SkeletonResponse(BaseModel):
    job_id: str
    received_at: datetime
    echo_payload: str
    sidecar_version: str


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "sidecar_version": SIDECAR_VERSION}


@app.post("/skeleton", dependencies=[Depends(require_bearer)])
def skeleton(req: SkeletonRequest) -> SkeletonResponse:
    return SkeletonResponse(
        job_id=req.job_id,
        received_at=datetime.now(timezone.utc),
        echo_payload="hello from sidecar",
        sidecar_version=SIDECAR_VERSION,
    )


@app.post(
    "/pipeline/run-validate",
    dependencies=[Depends(require_bearer)],
    response_model_exclude_none=True,
)
def pipeline_run_validate(req: PipelineRequest) -> PipelineResponse:
    """No-op contract validation endpoint (F-02).

    FastAPI validates the incoming `PipelineRequest` against the Pydantic model
    (the Python view of `shared/pipeline_schema.json`); a malformed body 422s.
    On success we echo back a minimal valid `PipelineResponse` so the Rails side
    can validate the response shape too — the full round-trip the F-02 spec
    requires. Real geometry runs in F-05–F-10's `/pipeline/run`.
    """
    if _schema_major(req.pipelineSchemaVersion) != _schema_major(PIPELINE_SCHEMA_VERSION):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"pipeline schema major mismatch: request {req.pipelineSchemaVersion} "
                f"vs sidecar {PIPELINE_SCHEMA_VERSION}"
            ),
        )

    return PipelineResponse(
        pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
        job_id=req.job.job_id,
        status=PipelineStatus.OK,
        measurement=Measurement(
            job_id=req.job.job_id,
            facets=[],
            features=[],
            source=GeometrySource.FUSION,
            confidence=0.0,
        ),
    )
