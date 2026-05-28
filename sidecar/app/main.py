"""RoofTrace Python sidecar — FastAPI app.

F-01 ships a stub `/skeleton` endpoint that echoes a payload with timestamps,
proving the Rails→sidecar IPC works end-to-end. Real geospatial endpoints
(/pipeline/run, /pipeline/fuse-capture, /pipeline/render-images) land in
F-05 through F-16."""

from __future__ import annotations

from datetime import datetime, timezone

from fastapi import Depends, FastAPI
from pydantic import BaseModel, Field

from .auth import require_bearer

SIDECAR_VERSION = "0.1.0"

app = FastAPI(title="rooftrace-sidecar", version=SIDECAR_VERSION)


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
