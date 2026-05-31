"""Plane fit + measurement — endpoints.

POST /pipeline/fit-planes (LiDAR path): `FitPlanesRequest` -> `MeasurementGeometry`.
POST /pipeline/fallback-measurement (no-LiDAR path): `FallbackMeasurementRequest`
  -> `MeasurementGeometry`.

RANSAC multi-plane fit, pitch from normals, pitch-corrected area, topology merge.
"""

from __future__ import annotations

import io
import logging

import numpy as np
from fastapi import APIRouter, HTTPException, status

from contracts.pipeline import (
    PIPELINE_SCHEMA_VERSION,
    FallbackMeasurementRequest,
    FitPlanesRequest,
    GeometrySource,
    MeasurementGeometry,
)
from ..pipeline_utils import check_pipeline_version
from ..storage import StorageError, get_bytes
from .geometry import (
    assemble_measurement,
    build_facets_from_planes,
    fallback_measurement_from_polygon,
)
from .plane_fit import fit_planes
from .topology import merge_coplanar_facets

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/pipeline", tags=["planefit"])

# Below this point count we return a sparse_lidar warning + single-facet best-effort.
_SPARSE_THRESHOLD = 100

# Cap the cropped point array a caller can ask us to load (a bearer holder could
# otherwise point a ref at a multi-GB object and exhaust memory). A residential
# building crop is well under this; raise if a real use case needs more.
_MAX_POINT_ARRAY_BYTES = 256 * 1024 * 1024  # 256 MiB


@router.post("/fit-planes", response_model=MeasurementGeometry)
def fit_planes_endpoint(req: FitPlanesRequest) -> MeasurementGeometry:
    """LiDAR path: RANSAC multi-plane fit → facet list with pitch + area.

    Steps:
    1. Fetch the cropped NumPy point array from storage.
    2. Run iterative RANSAC plane fitting.
    3. Topology cleanup (merge near-coplanar facets).
    4. Compute per-facet pitch, pitch-corrected area, WGS84 vertices.
    5. Return MeasurementGeometry.
    """
    check_pipeline_version(req.pipelineSchemaVersion)

    # --- Load point cloud ---
    try:
        raw_bytes = get_bytes(req.point_array_ref)
    except StorageError:
        # Generic detail — never echo the resolved path (leaks container layout).
        logger.warning("point_array_ref not found: %s", req.point_array_ref)
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="point_array_ref could not be read",
        )

    if len(raw_bytes) > _MAX_POINT_ARRAY_BYTES:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail="point array exceeds the maximum allowed size",
        )

    # allow_pickle=False: the bytes come from a storage ref; a crafted .npy/.npz
    # with a pickled object array would otherwise be an RCE vector. A malformed
    # or wrong-format object surfaces as a 422, not a 500.
    try:
        points = np.load(io.BytesIO(raw_bytes), allow_pickle=False)
    except (ValueError, OSError, EOFError) as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"point_array_ref is not a valid .npy array: {type(exc).__name__}",
        ) from exc

    if not isinstance(points, np.ndarray) or points.ndim != 2 or points.shape[1] < 3:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="point array must be a 2-D ndarray of shape (N, ≥3)",
        )

    # The LiDAR stage emits (N, 4) arrays [x, y, z, classification] (class already filtered
    # to building/6 upstream); other producers may emit bare (N, 3) xyz. Plane
    # fitting only needs xyz, so normalise to the first three columns here at the
    # ingest seam rather than threading column-count assumptions through RANSAC.
    points = points[:, :3]

    try:
        return _fit_and_measure(points, req)
    except ValueError as exc:
        # Bad caller input (e.g. an out-of-range utm_zone -> _utm_epsg) is a 422,
        # not an internal error the orchestrator should treat as retryable.
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"invalid measurement input: {exc}",
        ) from exc


def _fit_and_measure(points: np.ndarray, req: FitPlanesRequest) -> MeasurementGeometry:
    warnings: list[str] = []

    # --- Sparse path ---
    if len(points) < _SPARSE_THRESHOLD:
        logger.warning("Sparse LiDAR cloud: %d points", len(points))
        warnings.append("sparse_lidar")
        # Best-effort: fit one plane to the small cloud or return zero-facet response.
        if len(points) >= 3:
            planes = fit_planes(points, min_points=3)
            if planes:
                merged = merge_coplanar_facets(planes)
                facets = build_facets_from_planes(
                    merged, points, req.utm_zone, source=GeometrySource.LIDAR
                )
                # Cap confidence to <=0.3 (sparse cloud — low-trust geometry).
                # model_copy re-runs field validators so the Confidence bound is honoured.
                facets = [
                    f.model_copy(update={"confidence": min(f.confidence, 0.3)})
                    for f in facets
                ]
                result = assemble_measurement(facets, GeometrySource.LIDAR, warnings)
                # Also cap overall confidence.
                return result.model_copy(update={"confidence": min(result.confidence, 0.3)})

        return MeasurementGeometry(
            pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
            facets=[],
            total_area_sq_ft=0.0,
            primary_pitch_ratio=0.0,
            primary_pitch_degrees=0.0,
            source=GeometrySource.LIDAR,
            confidence=0.1,
            warnings=warnings,
        )

    # --- Normal path: RANSAC ---
    planes = fit_planes(points)

    if not planes:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="no_planes_found",
        )

    # --- Topology cleanup ---
    merged = merge_coplanar_facets(planes)

    # --- Build facets ---
    facets = build_facets_from_planes(merged, points, req.utm_zone, source=GeometrySource.LIDAR)

    if not facets:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="no_planes_found",
        )

    return assemble_measurement(facets, GeometrySource.LIDAR, warnings)


@router.post("/fallback-measurement", response_model=MeasurementGeometry)
def fallback_measurement_endpoint(req: FallbackMeasurementRequest) -> MeasurementGeometry:
    """No-LiDAR path: planimetric area / cos(inferred_pitch) → single imagery facet.

    Uses the refined_polygon as the footprint, applies the caller-supplied
    inferred_pitch_degrees, and returns a single facet with source=imagery and
    a lower confidence than the LiDAR path.
    """
    check_pipeline_version(req.pipelineSchemaVersion)
    polygon_coords = req.refined_polygon.coordinates
    try:
        return fallback_measurement_from_polygon(
            polygon_coords=polygon_coords,
            inferred_pitch_degrees=req.inferred_pitch_degrees,
            utm_zone=req.utm_zone,
        )
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=str(exc),
        ) from exc
