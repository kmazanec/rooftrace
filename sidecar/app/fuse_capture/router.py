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

import numpy as np
from fastapi import APIRouter, HTTPException, status

from contracts.pipeline import (
    PIPELINE_SCHEMA_VERSION,
    FuseCaptureRequest,
    FuseCaptureResponse,
    GeometrySource,
    Measurement,
)
from ..planefit.geometry import assemble_measurement, build_facets_from_planes
from ..planefit.plane_fit import fit_planes
from ..planefit.topology import merge_coplanar_facets
from ..storage import StorageError, get_bytes
from .icp import align_mesh_to_lidar
from .mesh_io import MeshTooLargeError, parse_obj

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/pipeline", tags=["fuse_capture"])

# Per-blob size guard: a bearer holder could otherwise point a ref at a multi-GB
# object and exhaust memory. A residential capture mesh / LiDAR crop is far under.
_MAX_BLOB_BYTES = 256 * 1024 * 1024  # 256 MiB


def _major(version: str) -> str:
    return version.split(".", 1)[0]


def _check_version(req_version: str) -> None:
    if _major(req_version) != _major(PIPELINE_SCHEMA_VERSION):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"pipeline schema major mismatch: request {req_version} "
                f"vs sidecar {PIPELINE_SCHEMA_VERSION}"
            ),
        )


def _utm_zone_from_lon(lon: float) -> int:
    """WGS84/UTM north zone number (1..60) for a longitude."""
    return int(((lon + 180.0) / 6.0) // 1 + 1)


def _utm_epsg_from_lon(lon: float) -> int:
    """Northern-hemisphere UTM EPSG (326xx) for a longitude (RoofTrace is CONUS)."""
    return 32_600 + _utm_zone_from_lon(lon)


def _load_blob(ref: str, what: str) -> bytes:
    try:
        raw = get_bytes(ref)
    except StorageError:
        # Generic detail — never echo the resolved path (leaks container layout).
        logger.warning("%s ref not found: %s", what, ref)
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"{what} could not be read",
        )
    if len(raw) > _MAX_BLOB_BYTES:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"{what} exceeds the maximum allowed size",
        )
    return raw


@router.post("/fuse-capture", response_model=FuseCaptureResponse)
def fuse_capture_endpoint(req: FuseCaptureRequest) -> FuseCaptureResponse:
    _check_version(req.pipelineSchemaVersion)

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
    if not isinstance(gps_seed, dict) or "longitude" not in gps_seed:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="session manifest is missing gps_origin",
        )

    # UTM EPSG: prefer the prior LiDAR work-unit's epsg; else derive from the GPS
    # origin longitude (the same zone formula the geometry pipeline uses).
    utm_epsg = None
    if req.lidar and req.lidar.work_unit and req.lidar.work_unit.epsg:
        utm_epsg = req.lidar.work_unit.epsg
    if utm_epsg is None:
        utm_epsg = _utm_epsg_from_lon(float(gps_seed["longitude"]))
    utm_zone = utm_epsg - 32_600

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
    lidar_pts = np.asarray(lidar_arr[:, :3], dtype=np.float64)

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
    aligned_mesh = (
        np.column_stack([mesh_pts, np.ones(len(mesh_pts))]) @ result.transformation.T
    )[:, :3]
    merged = np.vstack([lidar_pts, aligned_mesh])

    planes = fit_planes(merged)
    facets = []
    if planes:
        facets = build_facets_from_planes(
            merge_coplanar_facets(planes), merged, utm_zone, source=GeometrySource.FUSION
        )
    geometry = assemble_measurement(facets, GeometrySource.FUSION, warnings=[])

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

    return FuseCaptureResponse(
        pipelineSchemaVersion=PIPELINE_SCHEMA_VERSION,
        job_id=req.job_id,
        measurement=measurement,
        icp_rmse_m=result.rmse_m,
    )
