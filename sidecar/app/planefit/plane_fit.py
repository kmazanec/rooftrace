"""Pure-NumPy RANSAC multi-plane fitting for roof point clouds.

Algorithm:
  1. Randomly sample 3 points to form a plane hypothesis.
  2. Count inliers (|signed_dist| <= threshold).
  3. Repeat for max_iterations; keep best plane.
  4. Accept plane if inlier_ratio >= min_inlier_ratio AND inlier std <= max_residual_std.
  5. Peel inliers from the cloud and repeat until < min_points remain.

Output per plane:
  normal      — unit normal [nx, ny, nz]
  d           — plane equation ax+by+cz+d=0 offset
  inlier_mask — boolean mask into the full cloud slice passed to this call
  inlier_ratio
  residual_std
  centroid    — mean of inlier points
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import numpy.typing as npt

# ---------------------------------------------------------------------------
# RANSAC parameters (configurable via kwargs in fit_planes())
# ---------------------------------------------------------------------------
_DEFAULT_DISTANCE_THRESHOLD = 0.15  # metres
_DEFAULT_MAX_ITERATIONS = 200
# Minimum fraction of the *current residual cloud* that must be inliers.
# For iterative peeling, each iteration sees fewer points; a gable's first
# plane has ~50% of the full cloud, but a mansard's first plane has only
# ~12.5% (1 of 8 equal facets).  We use 0.08 as the floor — low enough
# to handle up to ~12 co-present planes while still requiring that at
# least 8% of the residual cloud supports the candidate plane.
# The primary quality gate is residual_std ≤ max_residual_std.
_DEFAULT_MIN_INLIER_RATIO = 0.08
_DEFAULT_MAX_RESIDUAL_STD = 0.15  # metres
_DEFAULT_MIN_POINTS = 30  # stop peeling below this
# Vertical walls (pitch > 75 deg) are excluded from roof facets.
_MAX_ROOF_PITCH_DEG = 75.0


@dataclass
class FittedPlane:
    normal: npt.NDArray[np.float64]  # unit vector [nx, ny, nz]
    d: float  # plane constant: dot(normal, p) + d = 0
    inlier_indices: npt.NDArray[np.intp]  # global indices into original cloud
    inlier_ratio: float
    residual_std: float
    centroid: npt.NDArray[np.float64]


def _plane_from_3pts(
    p0: npt.NDArray, p1: npt.NDArray, p2: npt.NDArray
) -> tuple[npt.NDArray, float] | None:
    """Return (unit_normal, d) or None if points are degenerate."""
    v1 = p1 - p0
    v2 = p2 - p0
    normal = np.cross(v1, v2)
    norm = np.linalg.norm(normal)
    if norm < 1e-9:
        return None
    normal = normal / norm
    d = -float(np.dot(normal, p0))
    return normal, d


def _signed_distances(
    points: npt.NDArray, normal: npt.NDArray, d: float
) -> npt.NDArray[np.float64]:
    return points @ normal + d  # shape (N,)


def _ransac_single_plane(
    points: npt.NDArray,
    distance_threshold: float,
    max_iterations: int,
    rng: np.random.Generator,
) -> tuple[npt.NDArray, float, npt.NDArray[np.bool_]] | None:
    """Fit one plane via RANSAC.

    Returns (normal, d, inlier_mask) or None if < 3 points.
    """
    n = len(points)
    if n < 3:
        return None
    best_count = 0
    best_normal = None
    best_mask: npt.NDArray[np.bool_] = np.zeros(n, dtype=bool)

    for _ in range(max_iterations):
        idx = rng.choice(n, size=3, replace=False)
        p0, p1, p2 = points[idx]
        result = _plane_from_3pts(p0, p1, p2)
        if result is None:
            continue
        normal, d = result
        dists = np.abs(_signed_distances(points, normal, d))
        mask = dists < distance_threshold
        count = int(mask.sum())
        if count > best_count:
            best_count = count
            best_normal = normal
            best_mask = mask

    if best_normal is None or best_count < 3:
        return None
    # Refine: re-fit using all inliers (least-squares plane).
    inlier_pts = points[best_mask]
    centroid = inlier_pts.mean(axis=0)
    _, _, Vt = np.linalg.svd(inlier_pts - centroid, full_matrices=False)
    normal_refined = Vt[-1]  # last row = smallest singular value = normal
    # Ensure the z-component is always upward (so pitch is measured correctly).
    if normal_refined[2] < 0:
        normal_refined = -normal_refined
    d_refined = -float(np.dot(normal_refined, centroid))
    # Re-compute inliers with refined plane.
    dists = np.abs(_signed_distances(points, normal_refined, d_refined))
    best_mask = dists < distance_threshold
    return normal_refined, d_refined, best_mask


def _pitch_degrees_from_normal(normal: npt.NDArray) -> float:
    """Roof pitch = angle between plane normal and vertical [0,0,1]."""
    nz = float(np.clip(abs(normal[2]), 0.0, 1.0))
    pitch_rad = np.arccos(nz)
    return float(np.degrees(pitch_rad))


def fit_planes(
    points: npt.NDArray,
    distance_threshold: float = _DEFAULT_DISTANCE_THRESHOLD,
    max_iterations: int = _DEFAULT_MAX_ITERATIONS,
    min_inlier_ratio: float = _DEFAULT_MIN_INLIER_RATIO,
    max_residual_std: float = _DEFAULT_MAX_RESIDUAL_STD,
    min_points: int = _DEFAULT_MIN_POINTS,
    seed: int = 42,
) -> list[FittedPlane]:
    """Iterative RANSAC multi-plane fit.

    Peels planes one at a time from the residual cloud until fewer than
    ``min_points`` remain or no acceptable plane can be found.

    Acceptance criteria per plane:
      - inlier_ratio >= min_inlier_ratio
      - residual std of inlier distances <= max_residual_std
      - pitch < _MAX_ROOF_PITCH_DEG (reject vertical walls)
    """
    if points.ndim != 2 or points.shape[1] < 3:
        return []

    rng = np.random.default_rng(seed)
    # Work with integer indices into the original array.
    residual_idx = np.arange(len(points), dtype=np.intp)
    planes: list[FittedPlane] = []

    while len(residual_idx) >= min_points:
        cloud_slice = points[residual_idx]
        result = _ransac_single_plane(cloud_slice, distance_threshold, max_iterations, rng)
        if result is None:
            break

        normal, d, local_mask = result
        n_total = len(cloud_slice)
        n_inliers = int(local_mask.sum())

        if n_inliers < 3:
            break

        inlier_ratio = n_inliers / n_total

        # Residual std on inlier signed distances.
        inlier_pts = cloud_slice[local_mask]
        dists = np.abs(_signed_distances(inlier_pts, normal, d))
        residual_std = float(dists.std())

        # Check acceptance criteria.
        pitch = _pitch_degrees_from_normal(normal)
        if (
            inlier_ratio >= min_inlier_ratio
            and residual_std <= max_residual_std
            and pitch < _MAX_ROOF_PITCH_DEG
        ):
            global_inlier_idx = residual_idx[local_mask]
            centroid = inlier_pts.mean(axis=0)
            planes.append(
                FittedPlane(
                    normal=normal,
                    d=d,
                    inlier_indices=global_inlier_idx,
                    inlier_ratio=inlier_ratio,
                    residual_std=residual_std,
                    centroid=centroid,
                )
            )
            # Peel inliers from residual.
            residual_idx = residual_idx[~local_mask]
        else:
            # Can't fit an acceptable plane from this residual — stop.
            break

    return planes


def point_density(n_points: int, area_m2: float) -> float:
    """Points per square metre; clamp to a small positive value."""
    if area_m2 <= 0:
        return 0.0
    return n_points / area_m2


def facet_confidence(inlier_ratio: float, pts_per_m2: float) -> float:
    """Per-facet confidence in [0, 1].

    Formula (documented):
      conf = 0.6 * inlier_ratio_score + 0.4 * density_score

    where:
      inlier_ratio_score = inlier_ratio  (already in [0,1])
      density_score      = min(pts_per_m2 / 10.0, 1.0)
                           (saturates at 10 pts/m², typical LiDAR density)

    Rationale:
      - Inlier ratio is the primary quality signal: a 95 % ratio means the
        plane model explains 95 % of the local points.
      - Density penalises sparse patches where RANSAC has few samples to work
        with. Saturation at 10 pts/m² keeps typical high-density LiDAR from
        dominating; below ~1 pt/m² the score drops noticeably.
    """
    density_score = min(pts_per_m2 / 10.0, 1.0)
    return float(np.clip(0.6 * inlier_ratio + 0.4 * density_score, 0.0, 1.0))
