"""render-images stage — POST /pipeline/render-images.

Renders a deterministic top-down map PNG for the roof report (see ADR-014
§Amendment 2026-05-28: a SINGLE ``image_ref`` under the Spaces ``artifacts/``
prefix — oblique/3D views are deferred). The rendered PNG is stored to Spaces under
``artifacts/<job_id>/images/map-<hash>.png`` and its storage key is returned.

This is DISTINCT from ``/pipeline/render-imagery`` (the satellite tile the
geometry pipeline consumes): that serves SAM2/VLM; this serves the report
surfaces.

Auth: shared-secret bearer injected by main.py (Depends(require_bearer)).

NOTE: this module lands the endpoint CONTRACT (request/response shape, version
check, WGS84-sane bbox guard, storage-key convention). The real MapLibre map
rendering is supplied by the report workstream; the contract-level renderer
here emits a deterministic placeholder PNG of the requested size so the shape
and storage convention are exercised end-to-end without a browser dependency.
"""

from __future__ import annotations

import hashlib
import logging

from fastapi import APIRouter, HTTPException, status

from app.storage import put_bytes

from contracts.pipeline import (
    PIPELINE_SCHEMA_VERSION,
    RenderImageRequest,
    RenderImageResponse,
)

from .renderer import render_png

router = APIRouter(prefix="/pipeline", tags=["render-images"])
logger = logging.getLogger(__name__)


def _major(version: str) -> str:
    return version.split(".", 1)[0]


def _storage_key(job_id: str, bbox: list[float], width_px: int, height_px: int) -> str:
    """``artifacts/<job_id>/images/map-<hash>.png`` — deterministic in the
    request so a re-render of the same view reuses the same key."""
    canonical = f"{bbox}|{width_px}x{height_px}"
    digest = hashlib.sha256(canonical.encode()).hexdigest()[:24]
    return f"artifacts/{job_id}/images/map-{digest}.png"


@router.post(
    "/render-images",
    response_model=RenderImageResponse,
    response_model_exclude_none=True,
)
def render_images_endpoint(req: RenderImageRequest) -> RenderImageResponse:
    if _major(req.pipelineSchemaVersion) != _major(PIPELINE_SCHEMA_VERSION):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"pipeline schema major mismatch: request {req.pipelineSchemaVersion} "
                f"vs sidecar {PIPELINE_SCHEMA_VERSION}"
            ),
        )

    min_lon, min_lat, max_lon, max_lat = req.bbox
    in_range = (
        -180.0 <= min_lon <= 180.0
        and -180.0 <= max_lon <= 180.0
        and -90.0 <= min_lat <= 90.0
        and -90.0 <= max_lat <= 90.0
    )
    if not (in_range and min_lon < max_lon and min_lat < max_lat):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="bbox must be a WGS84 [min_lon, min_lat, max_lon, max_lat] with min < max",
        )

    try:
        png = render_png(req.bbox, req.width_px, req.height_px)
        image_ref = put_bytes(
            _storage_key(req.job_id, req.bbox, req.width_px, req.height_px), png
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("render-images failed: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"map render failed: {type(exc).__name__}",
        ) from exc

    return RenderImageResponse(
        pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
        job_id=req.job_id,
        image_ref=image_ref,
    )
