"""F-08 Plane fit + measurement — endpoints.

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
    FallbackMeasurementRequest,
    FitPlanesRequest,
    GeometrySource,
    MeasurementGeometry,
)
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
    # --- Load point cloud ---
    try:
        raw_bytes = get_bytes(req.point_array_ref)
    except StorageError as e:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"point_array_ref not found: {e}",
        )

    points = np.load(io.BytesIO(raw_bytes))

    if points.ndim != 2 or points.shape[1] < 3:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="point array must be shape (N, ≥3)",
        )

    # F-06 emits (N, 4) arrays [x, y, z, classification] (class already filtered
    # to building/6 upstream); other producers may emit bare (N, 3) xyz. Plane
    # fitting only needs xyz, so normalise to the first three columns here at the
    # ingest seam rather than threading column-count assumptions through RANSAC.
    points = points[:, :3]

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
                # Cap confidence to <=0.3.
                for f in facets:
                    object.__setattr__(f, "confidence", min(f.confidence, 0.3))
                result = assemble_measurement(facets, GeometrySource.LIDAR, warnings)
                # Also cap overall confidence.
                return MeasurementGeometry(
                    **{**result.model_dump(), "confidence": min(result.confidence, 0.3)}
                )

        return MeasurementGeometry(
            pipelineSchemaVersion=req.pipelineSchemaVersion,
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
    polygon_coords = req.refined_polygon.coordinates
    return fallback_measurement_from_polygon(
        polygon_coords=polygon_coords,
        inferred_pitch_degrees=req.inferred_pitch_degrees,
        utm_zone=req.utm_zone,
    )
