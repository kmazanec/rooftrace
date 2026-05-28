"""F-06 LiDAR ingest — POST /pipeline/ingest-lidar.

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

from fastapi import APIRouter, HTTPException, status

from app.storage import put_bytes

from contracts.pipeline import (
    PIPELINE_SCHEMA_VERSION,
    GeometrySource,
    IngestLidarRequest,
    IngestLidarResponse,
    LiDARResult,
    LiDARStatus,
    WorkUnit as ContractWorkUnit,
)

from . import ingest as ingest_mod
from .ingest import IngestOutcome
from .wesm import WorkUnit as WesmWorkUnit
from .wesm import default_index

router = APIRouter(prefix="/pipeline", tags=["lidar"])


def _major(version: str) -> str:
    return version.split(".", 1)[0]


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
    if outcome.status == "LIDAR_AVAILABLE":
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
            [
                {
                    "name": "USGS 3DEP",
                    "license": "Public Domain (USGS)",
                    "url": "https://www.usgs.gov/3d-elevation-program",
                }
            ]
            if outcome.status == "LIDAR_AVAILABLE"
            else []
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
    if _major(req.pipelineSchemaVersion) != _major(PIPELINE_SCHEMA_VERSION):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"pipeline schema major mismatch: request {req.pipelineSchemaVersion} "
                f"vs sidecar {PIPELINE_SCHEMA_VERSION}"
            ),
        )

    building_polygon = req.building_polygon.model_dump(exclude_none=True)
    try:
        outcome = ingest_mod.ingest_lidar(
            building_polygon,
            index=_resolve_index(),
            cropper=_resolve_cropper(),
            put_bytes=put_bytes,
        )
    except Exception as exc:  # PDAL/S3/CRS failures: 5xx with the message logged.
        # Never leak internals to the caller; the orchestrator treats this as a
        # failed stage. The detail is intentionally generic.
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"lidar ingest failed: {type(exc).__name__}",
        ) from exc

    return _outcome_to_response(PIPELINE_SCHEMA_VERSION, outcome)
