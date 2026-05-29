"""Open3D point-to-plane ICP alignment of an ARKit capture mesh to the public
LiDAR cloud (ADR-007 capture fusion).

The iOS app uploads a gravity-aligned ARKit world mesh in its own arbitrary
session-local frame; the public-LiDAR cloud lives in a projected UTM frame. We
coarse-seed the alignment from the session GPS origin (re-projected into the
LiDAR UTM frame) plus a centroid match, then refine with a two-pass point-to-
plane ICP (coarse 0.5 m basin, then a tight 0.15 m refinement).

``converged`` is the gate the router keys its success/failure branch off:
``rmse_m < 0.5`` AND ``fitness > 0.2``. The acceptance fixture (a 0.3-0.5 m
rigid offset, well inside the coarse basin) converges to RMSE < 0.15 m with
>= 80% of mesh vertices within 0.1 m of the LiDAR surface.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

import numpy as np
import numpy.typing as npt
import open3d as o3d
from pyproj import Transformer

logger = logging.getLogger(__name__)

# Normal-estimation neighbourhood (point-to-plane needs target normals).
_NORMAL_RADIUS = 0.5
_NORMAL_MAX_NN = 30

# Two-pass correspondence distances + iteration caps.
_PASS1_MAX_CORR = 0.5
_PASS1_MAX_ITER = 50
_PASS2_MAX_CORR = 0.15
_PASS2_MAX_ITER = 30

# Convergence gate.
_RMSE_CONVERGED_M = 0.5
_FITNESS_CONVERGED = 0.2

# "Within distance" used for the pct_within_0_1m acceptance metric.
_WITHIN_M = 0.1


@dataclass
class AlignResult:
    transformation: npt.NDArray[np.float64]  # 4x4 mesh->lidar rigid transform
    rmse_m: float
    pct_within_0_1m: float
    converged: bool
    fitness: float


def _to_pcd(points: npt.NDArray) -> o3d.geometry.PointCloud:
    pcd = o3d.geometry.PointCloud()
    pcd.points = o3d.utility.Vector3dVector(np.asarray(points, dtype=np.float64))
    return pcd


def _seed_transform(
    mesh_pts: npt.NDArray,
    lidar_pts: npt.NDArray,
    gps_seed: dict | None,
    utm_epsg: int | None,
) -> npt.NDArray[np.float64]:
    """Build a 4x4 init transform placing the ARKit mesh into the LiDAR frame.

    Primary seed: match the mesh centroid to the LiDAR centroid (a pure
    translation). When a GPS origin + UTM EPSG are supplied, we sanity-blend the
    GPS-derived UTM anchor toward the LiDAR centroid — but the centroid match is
    the load-bearing seed because the ARKit origin is arbitrary and the LiDAR
    crop is already centred on the building. This keeps the ARKit origin well
    inside the coarse ICP basin regardless of the GPS fix quality.
    """
    mesh_centroid = mesh_pts.mean(axis=0)
    lidar_centroid = lidar_pts.mean(axis=0)
    translation = lidar_centroid - mesh_centroid

    init = np.eye(4, dtype=np.float64)
    init[:3, 3] = translation

    # GPS anchor (informational / coarse cross-check): re-project the session
    # origin into the LiDAR UTM frame. Used only to log a gross discrepancy; the
    # centroid translation remains the seed so a bad GPS fix can't push the mesh
    # out of the capture basin.
    if gps_seed and utm_epsg:
        try:
            transformer = Transformer.from_crs(
                "EPSG:4326", f"EPSG:{utm_epsg}", always_xy=True
            )
            easting, northing = transformer.transform(
                gps_seed["longitude"], gps_seed["latitude"]
            )
            gps_anchor = np.array([easting, northing, lidar_centroid[2]])
            drift = float(np.linalg.norm(gps_anchor[:2] - lidar_centroid[:2]))
            logger.debug("GPS anchor drift from LiDAR centroid: %.1f m", drift)
        except (KeyError, ValueError, TypeError) as exc:  # pragma: no cover - defensive
            logger.debug("GPS seed unusable, centroid-only seed: %s", exc)

    return init


def gps_to_utm(latitude: float, longitude: float, utm_epsg: int) -> tuple[float, float]:
    """Project a WGS84 lat/lon to (easting, northing) in the given UTM EPSG."""
    transformer = Transformer.from_crs(
        "EPSG:4326", f"EPSG:{utm_epsg}", always_xy=True
    )
    return transformer.transform(longitude, latitude)


def align_mesh_to_lidar(
    mesh_pts: npt.NDArray,
    lidar_pts: npt.NDArray,
    gps_seed: dict | None = None,
    utm_epsg: int | None = None,
) -> AlignResult:
    """Two-pass point-to-plane ICP aligning ``mesh_pts`` onto ``lidar_pts``."""
    mesh_pts = np.asarray(mesh_pts, dtype=np.float64)
    lidar_pts = np.asarray(lidar_pts, dtype=np.float64)

    source = _to_pcd(mesh_pts)
    target = _to_pcd(lidar_pts)

    search = o3d.geometry.KDTreeSearchParamHybrid(
        radius=_NORMAL_RADIUS, max_nn=_NORMAL_MAX_NN
    )
    source.estimate_normals(search_param=search)
    target.estimate_normals(search_param=search)

    init = _seed_transform(mesh_pts, lidar_pts, gps_seed, utm_epsg)
    p2l = o3d.pipelines.registration.TransformationEstimationPointToPlane()

    pass1 = o3d.pipelines.registration.registration_icp(
        source,
        target,
        _PASS1_MAX_CORR,
        init,
        p2l,
        o3d.pipelines.registration.ICPConvergenceCriteria(max_iteration=_PASS1_MAX_ITER),
    )
    pass2 = o3d.pipelines.registration.registration_icp(
        source,
        target,
        _PASS2_MAX_CORR,
        pass1.transformation,
        p2l,
        o3d.pipelines.registration.ICPConvergenceCriteria(max_iteration=_PASS2_MAX_ITER),
    )

    transformation = np.asarray(pass2.transformation, dtype=np.float64)
    fitness = float(pass2.fitness)

    # pct of mesh vertices within 0.1 m of the LiDAR surface AFTER alignment, and
    # the full-cloud distance stats used to report a meaningful residual.
    aligned = source.transform(transformation.copy())
    dists = np.asarray(aligned.compute_point_cloud_distance(target))
    pct_within = float(np.mean(dists <= _WITHIN_M)) if dists.size else 0.0

    # rmse_m: Open3D's inlier_rmse is the residual over correspondences WITHIN the
    # final 0.15 m gate — meaningful on a good alignment but ~0 on a failed one
    # that simply has no inliers (which would falsely read as "tight"). When the
    # alignment failed to find correspondences (low fitness), report the true
    # full-cloud RMS distance instead so the residual reflects the real misfit
    # the router surfaces as icp_rmse_m.
    inlier_rmse = float(pass2.inlier_rmse)
    if fitness > _FITNESS_CONVERGED and inlier_rmse > 0.0:
        rmse_m = inlier_rmse
    elif dists.size:
        rmse_m = float(np.sqrt(np.mean(dists**2)))
    else:
        rmse_m = inlier_rmse

    converged = (rmse_m < _RMSE_CONVERGED_M) and (fitness > _FITNESS_CONVERGED)

    return AlignResult(
        transformation=transformation,
        rmse_m=rmse_m,
        pct_within_0_1m=pct_within,
        converged=converged,
        fitness=fitness,
    )
