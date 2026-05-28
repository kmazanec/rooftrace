"""F-10.1 render-imagery stage — POST /pipeline/render-imagery.

Fetches a NAIP satellite tile for a building polygon, crops to the padded
bbox, stores the PNG to Spaces ``cache/imagery/<hash>.png``, and returns the
storage key plus geo-bounds.

Auth: shared-secret bearer injected by main.py (Depends(require_bearer)).
Real path: gated by IMAGERY_LIVE=1; fixture fallback is the default (hermetic CI).
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, HTTPException, status

from app.storage import put_bytes

from contracts.pipeline import (
    PIPELINE_SCHEMA_VERSION,
    AttributionItem,
    RenderImageryRequest,
    RenderImageryResponse,
)

from .naip import render_imagery

router = APIRouter(prefix="/pipeline", tags=["imagery"])
logger = logging.getLogger(__name__)


def _major(version: str) -> str:
    return version.split(".", 1)[0]


@router.post(
    "/render-imagery",
    response_model=RenderImageryResponse,
    response_model_exclude_none=True,
)
def render_imagery_endpoint(req: RenderImageryRequest) -> RenderImageryResponse:
    """Fetch + cache a NAIP tile for the given building polygon (F-10.1).

    - Version-major mismatch → 409.
    - Out-of-range WGS84 coords → 422.
    - Real NAIP fetch gated by IMAGERY_LIVE=1; fixture PNG otherwise.
    - PNG stored to Spaces under cache/imagery/<hash>.png.
    """
    # 1. Version check
    if _major(req.pipelineSchemaVersion) != _major(PIPELINE_SCHEMA_VERSION):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"pipeline schema major mismatch: request {req.pipelineSchemaVersion} "
                f"vs sidecar {PIPELINE_SCHEMA_VERSION}"
            ),
        )

    # 2. Validate building polygon coords are WGS84-sane.
    building_polygon = req.building_polygon.model_dump(exclude_none=True)
    for ring in building_polygon.get("coordinates", []):
        for pt in ring:
            lon, lat = pt[0], pt[1]
            if not (-180.0 <= lon <= 180.0 and -90.0 <= lat <= 90.0):
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail="building_polygon has out-of-range WGS84 coordinates",
                )

    # 3. Fetch imagery (real or fixture).
    try:
        outcome = render_imagery(
            building_polygon=building_polygon,
            size_px=req.size_px,
            put_bytes=put_bytes,
            target_gsd_m=req.target_gsd_m,
        )
    except Exception as exc:
        logger.exception("render_imagery failed: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"imagery fetch failed: {type(exc).__name__}",
        ) from exc

    # 4. Build attribution list.
    attribution = [
        AttributionItem(
            name=outcome.attribution_name,
            license=outcome.attribution_license,
            url=outcome.attribution_url,
        )
    ]

    return RenderImageryResponse(
        pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
        image_tile_ref=outcome.image_key,
        image_geo_bounds=outcome.geo_bounds,
        attribution=attribution,
        warnings=outcome.warnings,
    )
