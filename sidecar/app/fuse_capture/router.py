"""iOS capture fusion endpoint (ADR-007).

POST /pipeline/fuse-capture : ``FuseCaptureRequest`` -> ``FuseCaptureResponse``.

Loads the uploaded ARKit world mesh and the cached public-LiDAR cloud, ICP-aligns
the mesh into the LiDAR frame (GPS-seeded point-to-plane, two-pass), and on
convergence merges the two clouds and re-runs the plane-fit pipeline to produce a
fused Measurement (source=fusion). On non-convergence it returns measurement=None
with the residual RMSE so Rails can leave the LiDAR-only measurement canonical.
"""

from __future__ import annotations

import io
import json
import logging
import math

import numpy as np
from fastapi import APIRouter, HTTPException, status

from contracts.pipeline import (
    PIPELINE_SCHEMA_VERSION,
    FuseCaptureRequest,
    FuseCaptureResponse,
    GeometrySource,
    Measurement,
)
from ..pipeline_utils import check_pipeline_version
from ..planefit.geometry import (
    assemble_measurement,
    build_facets_from_roof_model,
    build_facets_from_planes,
)
from ..planefit.plane_fit import fit_planes
from ..planefit.roof_model import build_roof_model, roof_model_diagnostics
from ..planefit.topology import merge_coplanar_facets
from ..storage import StorageError, get_bytes
from .icp import align_mesh_to_lidar
from .mesh_io import MeshTooLargeError, parse_obj

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/pipeline", tags=["fuse_capture"])

# Per-blob size guard: a bearer holder could otherwise point a ref at a multi-GB
# object and exhaust memory. A residential capture mesh / LiDAR crop is far under.
_MAX_BLOB_BYTES = 256 * 1024 * 1024  # 256 MiB

# Minimum LiDAR points to even attempt ICP. Below this, Open3D's KD-tree / normal
# estimation blows up with native errors (=> 500). Mirrors the plane-fit
# pipeline's sparse threshold so the two stages agree on "too sparse to use".
_MIN_LIDAR_POINTS = 100


def _coerce_finite_coordinate(value: object, name: str) -> float:
    """Parse a GPS coordinate, rejecting non-numeric / non-finite values (422)."""
    try:
        coord = float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError) as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"gps_origin.{name} must be a finite number",
        ) from exc
    if not math.isfinite(coord):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"gps_origin.{name} must be a finite number",
        )
    return coord


def _utm_zone_from_lon(lon: float) -> int:
    """WGS84/UTM north zone number (1..60) for a longitude."""
    return int(((lon + 180.0) / 6.0) // 1 + 1)


def _utm_epsg_from_lon(lon: float) -> int:
    """Northern-hemisphere UTM EPSG (326xx) for a longitude (RoofTrace is CONUS)."""
    return 32_600 + _utm_zone_from_lon(lon)


def _load_blob(ref: str, what: str) -> bytes:
    try:
        raw = get_bytes(ref)
    except StorageError as exc:
        # Generic detail — never echo the resolved path (leaks container layout).
        logger.warning("%s ref not found: %s", what, ref)
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"{what} could not be read",
        ) from exc
    if len(raw) > _MAX_BLOB_BYTES:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"{what} exceeds the maximum allowed size",
        )
    return raw


@router.post("/fuse-capture", response_model=FuseCaptureResponse)
def fuse_capture_endpoint(req: FuseCaptureRequest) -> FuseCaptureResponse:
    check_pipeline_version(req.pipelineSchemaVersion)

    # --- Session manifest (GPS seed + UTM projection) -----------------------
    session_bytes = _load_blob(f"uploads/{req.job_id}/session.json", "session manifest")
    try:
        manifest = json.loads(session_bytes)
    except json.JSONDecodeError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="session manifest is not valid JSON",
        ) from exc

    gps_seed = manifest.get("gps_origin")

    # gps_origin is OPTIONAL: the iOS app omits it entirely when the device had no
    # GPS fix (rather than writing a sentinel (0,0,9999) Null Island value that
    # downstream would mistake for real data).  When absent, skip all lat/lon
    # validation and UTM derivation; pass gps_seed=None to align_mesh_to_lidar so
    # ICP falls back to centroid-only alignment.
    #
    # When PRESENT, keep the existing strict validation — a non-numeric, NaN/Inf,
    # or out-of-range coordinate that slips through the Rails ingest must still
    # surface as a deterministic 422 rather than an unhandled ValueError/pyproj
    # error (=> 500 + retry loop).
    utm_epsg = None
    if gps_seed is not None:
        if not isinstance(gps_seed, dict) or "longitude" not in gps_seed or "latitude" not in gps_seed:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="gps_origin is present but malformed (missing latitude or longitude)",
            )

        lat = _coerce_finite_coordinate(gps_seed.get("latitude"), "latitude")
        lon = _coerce_finite_coordinate(gps_seed.get("longitude"), "longitude")
        if not -90.0 <= lat <= 90.0:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="gps_origin.latitude must be within [-90, 90]",
            )
        if not -180.0 <= lon <= 180.0:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="gps_origin.longitude must be within [-180, 180]",
            )

        # UTM EPSG: prefer the prior LiDAR work-unit's epsg; else derive from the
        # GPS origin longitude (the same zone formula the geometry pipeline uses).
        if req.lidar and req.lidar.work_unit and req.lidar.work_unit.epsg:
            utm_epsg = req.lidar.work_unit.epsg
        if utm_epsg is None:
            utm_epsg = _utm_epsg_from_lon(lon)
    else:
        # No GPS fix: prefer the prior LiDAR work-unit's epsg if available;
        # otherwise leave utm_epsg=None (centroid-only ICP, no UTM projection).
        if req.lidar and req.lidar.work_unit and req.lidar.work_unit.epsg:
            utm_epsg = req.lidar.work_unit.epsg

    utm_zone = utm_epsg - 32_600 if utm_epsg is not None else None

    # --- ARKit mesh ----------------------------------------------------------
    mesh_bytes = _load_blob(req.capture_mesh_ref, "capture mesh")
    try:
        mesh_pts = parse_obj(mesh_bytes)
    except MeshTooLargeError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=str(exc),
        ) from exc
    if mesh_pts.shape[0] < 3:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="capture mesh has too few vertices to align",
        )

    # --- LiDAR cloud ---------------------------------------------------------
    if req.lidar is None or not req.lidar.point_array_ref:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="lidar.point_array_ref is required for fusion",
        )
    lidar_bytes = _load_blob(req.lidar.point_array_ref, "lidar point array")
    # allow_pickle=False: the bytes come from a storage ref; a crafted .npy with a
    # pickled object array would otherwise be an RCE vector. A malformed/wrong
    # object surfaces as a 422, not a 500.
    try:
        lidar_arr = np.load(io.BytesIO(lidar_bytes), allow_pickle=False)
    except (ValueError, OSError, EOFError) as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"lidar point array is not a valid .npy: {type(exc).__name__}",
        ) from exc
    if not isinstance(lidar_arr, np.ndarray) or lidar_arr.ndim != 2 or lidar_arr.shape[1] < 3:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="lidar point array must be a 2-D ndarray of shape (N, >=3)",
        )
    if lidar_arr.shape[0] < _MIN_LIDAR_POINTS:
        # Too sparse to align: Open3D's normal estimation / KD-tree would raise a
        # native error (=> 500). Reject deterministically.
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"lidar point array has too few points to align (need >= {_MIN_LIDAR_POINTS})",
        )
    lidar_pts = np.asarray(lidar_arr[:, :3], dtype=np.float64)
    if not np.isfinite(lidar_pts).all():
        # NaN/Inf coordinates blow up ICP with native errors; reject as 422.
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="lidar point array contains non-finite coordinates",
        )

    # --- ICP alignment -------------------------------------------------------
    result = align_mesh_to_lidar(mesh_pts, lidar_pts, gps_seed=gps_seed, utm_epsg=utm_epsg)

    if not result.converged:
        # Leave the LiDAR-only measurement canonical; surface the residual.
        return FuseCaptureResponse(
            pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
            job_id=req.job_id,
            measurement=None,
            icp_rmse_m=result.rmse_m,
        )

    # --- Converged: merge clouds + re-run plane fit --------------------------
    # utm_epsg may be None when GPS was unavailable and the LiDAR work-unit carried
    # no prior EPSG. Without a UTM projection frame we cannot geo-register the
    # facets, so fall back to the LiDAR-only measurement (measurement=None) even on
    # ICP convergence. This mirrors the non-convergence branch: the sidecar reports
    # the RMSE and Rails leaves the LiDAR-only result canonical.
    if utm_epsg is None:
        return FuseCaptureResponse(
            pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
            job_id=req.job_id,
            measurement=None,
            icp_rmse_m=result.rmse_m,
        )

    aligned_mesh = (
        np.column_stack([mesh_pts, np.ones(len(mesh_pts))]) @ result.transformation.T
    )[:, :3]
    merged = np.vstack([lidar_pts, aligned_mesh])

    planes = fit_planes(merged)
    facets = []
    geometry_warnings: list[str] = []
    roof_model = None
    if planes:
        merged_planes = merge_coplanar_facets(planes)
        if req.refined_polygon is not None:
            roof_model = build_roof_model(merged_planes, merged, req.refined_polygon, utm_zone)
            facets = build_facets_from_roof_model(
                roof_model, utm_zone, source=GeometrySource.FUSION
            )
            geometry_warnings = roof_model.warnings
        else:
            facets = build_facets_from_planes(
                merged_planes, merged, utm_zone, source=GeometrySource.FUSION
            )
    geometry = assemble_measurement(
        facets,
        GeometrySource.FUSION,
        warnings=geometry_warnings,
        roof_model=roof_model_diagnostics(roof_model) if roof_model is not None else None,
    )

    # Adapt MeasurementGeometry -> Measurement (the FuseCaptureResponse shape):
    # MeasurementGeometry has no job_id/features and names the roll-up pitch
    # primary_pitch_ratio; Measurement wants job_id, features=[], and
    # predominant_pitch_ratio. See the frozen contract.
    measurement = Measurement(
        job_id=req.job_id,
        facets=geometry.facets,
        features=[],
        total_area_sq_ft=geometry.total_area_sq_ft,
        predominant_pitch_ratio=geometry.primary_pitch_ratio,
        source=GeometrySource.FUSION,
        confidence=geometry.confidence,
    )

    # The solved ICP transform (mesh/ARKit frame -> LiDAR UTM frame) and its UTM
    # EPSG are returned on convergence so the photo-projection stage reuses the
    # SOLVED transform instead of re-solving from the mesh. Flatten the 4x4 to a
    # row-major 16-float list (the FuseCaptureResponse arkit_to_utm shape). Rails
    # persists these to Measurement.provenance (one source of truth).
    arkit_to_utm = [float(x) for x in result.transformation.reshape(-1)]

    return FuseCaptureResponse(
        pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
        job_id=req.job_id,
        measurement=measurement,
        icp_rmse_m=result.rmse_m,
        arkit_to_utm=arkit_to_utm,
        utm_epsg=utm_epsg,
    )
