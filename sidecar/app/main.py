"""RoofTrace Python sidecar — FastAPI app.

The stub `/skeleton` endpoint echoes a payload with timestamps, proving the
Rails→sidecar IPC works end-to-end. The pipeline contract endpoint is
`/pipeline/run-validate`. The geospatial pipeline stages live in their own
modules and register their routes via an `APIRouter` that this module mounts —
so each stage owns its endpoint without fighting over this shared file. (VLM
feature detection lives in Rails per ADR-006, not here.)"""

from __future__ import annotations

from contextlib import asynccontextmanager
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
from .boot_checks import run_boot_checks
from .evidence.router import router as evidence_router
from .fuse_capture.router import router as fuse_capture_router
from .imagery.router import router as imagery_router
from .lidar.router import router as lidar_router
from .outline.router import router as outline_router
from .planefit.router import router as planefit_router
from .project_photo.router import router as project_photo_router
from .render_images.router import router as render_images_router
from .resolve_address.router import router as resolve_address_router

SIDECAR_VERSION = "0.1.0"


@asynccontextmanager
async def _lifespan(application: FastAPI):  # noqa: ARG001
    """FastAPI lifespan: run fail-fast boot checks before the first request.

    Raises RuntimeError (SIDECAR_ENV=production) or logs warnings (dev/unset)
    for enabled-but-misconfigured pipeline stages.  This fires at container
    start, not per-request, so a misconfigured deploy dies on boot with a
    clear message instead of booting green and 502-ing every pipeline call.
    """
    run_boot_checks()
    yield
    # (shutdown: nothing to tear down)


app = FastAPI(title="rooftrace-sidecar", version=SIDECAR_VERSION, lifespan=_lifespan)

# Each geospatial stage owns an APIRouter under /pipeline guarded by
# the shared-secret bearer. Mounted here once; the stage modules are filled in by
# their respective feature workstreams.
_PIPELINE_DEPS = [Depends(require_bearer)]
app.include_router(resolve_address_router, dependencies=_PIPELINE_DEPS)
app.include_router(lidar_router, dependencies=_PIPELINE_DEPS)
app.include_router(outline_router, dependencies=_PIPELINE_DEPS)
app.include_router(planefit_router, dependencies=_PIPELINE_DEPS)
app.include_router(imagery_router, dependencies=_PIPELINE_DEPS)
app.include_router(render_images_router, dependencies=_PIPELINE_DEPS)
app.include_router(fuse_capture_router, dependencies=_PIPELINE_DEPS)
app.include_router(evidence_router, dependencies=_PIPELINE_DEPS)
app.include_router(project_photo_router, dependencies=_PIPELINE_DEPS)


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
    """No-op contract validation endpoint.

    FastAPI validates the incoming `PipelineRequest` against the Pydantic model
    (the Python view of `shared/pipeline_schema.json`); a malformed body 422s.
    On success we echo back a minimal valid `PipelineResponse` so the Rails side
    can validate the response shape too — the full contract round-trip. Real
    geometry runs in the per-stage `/pipeline` endpoints.
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
