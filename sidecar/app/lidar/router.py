"""LiDAR ingest — POST /pipeline/ingest-lidar.

Takes an `IngestLidarRequest` (building_polygon + optional parcel_polygon) and
returns an `IngestLidarResponse` wrapping a `LiDARResult` plus the local UTM zone
and bounds. Coverage is checked against WESM first (fast-fail on a 3DEP gap);
on coverage the COPC is streamed/cropped/classified/reprojected and the cropped
array cached to Spaces (`cache/lidar/<hash>.npy`).

Auth: shared-secret bearer injected by main.py (Depends(require_bearer)).
The WESM index and the COPC cropper are resolved from the environment (real on
LIDAR_LIVE=1; fixture-backed in tests) so this module imports without PDAL/GDAL.
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, HTTPException, status
from shapely.geometry import shape

from app.pipeline_utils import schema_major
from app.storage import StorageError, StorageTooLargeError, get_bytes_capped, put_bytes

from contracts.pipeline import (
    PIPELINE_SCHEMA_VERSION,
    AttributionItem,
    GeometrySource,
    IngestLidarRequest,
    IngestLidarResponse,
    LidarPointsRequest,
    LidarPointsResponse,
    LiDARResult,
    LiDARStatus,
    WorkUnit as ContractWorkUnit,
)

from . import crs
from . import ingest as ingest_mod
from .ingest import IngestOutcome
from .wesm import WorkUnit as WesmWorkUnit
from .wesm import default_index

router = APIRouter(prefix="/pipeline", tags=["lidar"])

logger = logging.getLogger(__name__)

_3DEP_ATTRIBUTION = AttributionItem(
    name="USGS 3DEP",
    license="Public Domain (USGS)",
    url="https://www.usgs.gov/3d-elevation-program",
)


def _work_unit_to_contract(wu: WesmWorkUnit | None) -> ContractWorkUnit | None:
    if wu is None:
        return None
    return ContractWorkUnit(
        name=wu.name,
        year=wu.year,
        quality_level=wu.quality_level,
        epsg=wu.epsg,
    )


def _outcome_to_response(version: str, outcome: IngestOutcome) -> IngestLidarResponse:
    if outcome.status == LiDARStatus.AVAILABLE:
        lidar = LiDARResult(
            status=LiDARStatus.AVAILABLE,
            point_array_ref=outcome.point_array_ref,
            point_count=outcome.point_count,
            work_unit=_work_unit_to_contract(outcome.work_unit),
            source=GeometrySource.LIDAR,
            confidence=0.95,
        )
    else:
        # LIDAR_MISSING -> the pipeline degrades to imagery-only (ADR-001).
        lidar = LiDARResult(
            status=LiDARStatus.MISSING,
            point_array_ref=None,
            point_count=None,
            work_unit=_work_unit_to_contract(outcome.work_unit),
            source=GeometrySource.IMAGERY,
            confidence=0.0,
        )
    return IngestLidarResponse(
        pipelineSchemaVersion=version,
        lidar=lidar,
        utm_zone=outcome.utm_zone,
        bounds_utm=outcome.bounds_utm,
        warnings=outcome.warnings or [],
        attribution=(
            [_3DEP_ATTRIBUTION] if outcome.status == LiDARStatus.AVAILABLE else []
        ),
    )


# Injection seams so tests can supply a FixtureWesmIndex + FixtureCropper without
# monkeypatching the module internals.
def _resolve_index():
    return default_index()


def _resolve_cropper():
    return ingest_mod.default_cropper()


@router.post("/ingest-lidar", response_model=IngestLidarResponse, response_model_exclude_none=False)
def ingest_lidar(req: IngestLidarRequest) -> IngestLidarResponse:
    if schema_major(req.pipelineSchemaVersion) != schema_major(PIPELINE_SCHEMA_VERSION):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"pipeline schema major mismatch: request {req.pipelineSchemaVersion} "
                f"vs sidecar {PIPELINE_SCHEMA_VERSION}"
            ),
        )

    building_polygon = req.building_polygon.model_dump(exclude_none=True)

    # The contract type-checks coordinates as numbers but not their ranges; an
    # out-of-range lon/lat is bad CALLER input (422), not an infra failure (502),
    # so validate before the ingest so the broad except below is reserved for
    # genuine downstream PDAL/S3 errors.
    for ring in building_polygon.get("coordinates", []):
        for pt in ring:
            lon, lat = pt[0], pt[1]
            if not (-180.0 <= lon <= 180.0 and -90.0 <= lat <= 90.0):
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail="building_polygon has out-of-range WGS84 coordinates",
                )

    try:
        outcome = ingest_mod.ingest_lidar(
            building_polygon,
            index=_resolve_index(),
            cropper=_resolve_cropper(),
            put_bytes=put_bytes,
        )
    except Exception as exc:  # PDAL/S3/CRS failures: 5xx with the message logged.
        # Log the real cause (traceback) for operators; the orchestrator treats
        # this as a failed stage. The caller-facing detail stays generic so we
        # never leak internals (S3 keys, bucket names) to the response body.
        logger.warning("lidar ingest failed: %s", exc, exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"lidar ingest failed: {type(exc).__name__}",
        ) from exc

    return _outcome_to_response(PIPELINE_SCHEMA_VERSION, outcome)


@router.post("/lidar-points", response_model=LidarPointsResponse)
def lidar_points(req: LidarPointsRequest) -> LidarPointsResponse:
    """Decode a cached cropped LiDAR array into WGS84 overlay points (ADR-013
    interactive report overlay). The local UTM zone the cached points are in is
    derived from the building-polygon centroid — the same deterministic function
    the ingest used to reproject them — so UTM stays internal (ADR-003) and only
    WGS84 [lon, lat, elev_ft] crosses back."""
    if schema_major(req.pipelineSchemaVersion) != schema_major(PIPELINE_SCHEMA_VERSION):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"pipeline schema major mismatch: request {req.pipelineSchemaVersion} "
                f"vs sidecar {PIPELINE_SCHEMA_VERSION}"
            ),
        )

    max_points = req.max_points or ingest_mod.DEFAULT_MAX_OVERLAY_POINTS
    centroid = shape(req.building_polygon.model_dump(exclude_none=True)).centroid
    utm_zone = crs.utm_epsg_for(centroid.x, centroid.y)

    try:
        npy_bytes = get_bytes_capped(req.point_array_ref, ingest_mod.MAX_POINT_ARRAY_BYTES)
        overlay = ingest_mod.load_overlay_points(
            npy_bytes, utm_zone=utm_zone, max_points=max_points
        )
    except StorageTooLargeError as exc:
        logger.warning("lidar-points array over cap: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="lidar point array too large",
        ) from exc
    except StorageError as exc:
        # Missing/unreadable cache object — the points are gone (e.g. cache TTL).
        logger.info("lidar-points cache miss: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="lidar point array not found",
        ) from exc
    except Exception as exc:  # decode/reproject failure: 5xx, message logged.
        logger.warning("lidar-points failed: %s", exc, exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"lidar points failed: {type(exc).__name__}",
        ) from exc

    return LidarPointsResponse(
        pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
        points=overlay.points,
        point_count=overlay.point_count,
        returned_count=overlay.returned_count,
        bounds=overlay.bounds,
    )
