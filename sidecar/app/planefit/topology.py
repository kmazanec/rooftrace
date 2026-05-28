"""Topology cleanup: merge near-coplanar facets.

Two fitted planes are merged when:
  - The angle between their normals < 5 degrees (near-coplanar)
  - The distance between their centroids projected onto either normal < 0.3 m

Merging replaces both planes with a single averaged plane whose inliers are
the union of both planes' inlier sets.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
import numpy.typing as npt

from .plane_fit import FittedPlane

_MAX_NORMAL_ANGLE_DEG = 5.0
_MAX_CENTROID_DIST_M = 0.3


@dataclass
class MergedPlane:
    """A (possibly merged) fitted plane, ready for geometry computation."""

    normal: npt.NDArray[np.float64]
    d: float
    inlier_indices: npt.NDArray[np.intp]
    inlier_ratio: float
    residual_std: float
    centroid: npt.NDArray[np.float64]
    merged_from: list[int] = field(default_factory=list)  # indices of source planes


def _angle_between_normals(n1: npt.NDArray, n2: npt.NDArray) -> float:
    """Angle in degrees between two unit normals (0–90 deg)."""
    cos_angle = float(np.clip(abs(np.dot(n1, n2)), 0.0, 1.0))
    return float(np.degrees(np.arccos(cos_angle)))


def _plane_plane_dist(
    n1: npt.NDArray, d1: float, c2: npt.NDArray
) -> float:
    """Distance from centroid c2 to plane (n1, d1): |n1·c2 + d1|."""
    return float(abs(np.dot(n1, c2) + d1))


def _merge_two(p1: FittedPlane | MergedPlane, p2: FittedPlane | MergedPlane) -> MergedPlane:
    """Merge p2 into p1: average normal, union inliers, weighted centroid."""
    all_idx = np.unique(np.concatenate([p1.inlier_indices, p2.inlier_indices]))
    n1_weight = len(p1.inlier_indices)
    n2_weight = len(p2.inlier_indices)
    total = n1_weight + n2_weight

    # Weighted average of normals, then re-normalise.
    avg_normal = (p1.normal * n1_weight + p2.normal * n2_weight) / total
    norm = np.linalg.norm(avg_normal)
    if norm > 1e-9:
        avg_normal = avg_normal / norm
    if avg_normal[2] < 0:
        avg_normal = -avg_normal

    centroid = (p1.centroid * n1_weight + p2.centroid * n2_weight) / total
    d = -float(np.dot(avg_normal, centroid))

    avg_inlier_ratio = (p1.inlier_ratio * n1_weight + p2.inlier_ratio * n2_weight) / total
    avg_residual_std = (p1.residual_std * n1_weight + p2.residual_std * n2_weight) / total

    merged_from: list[int] = []
    if hasattr(p1, "merged_from"):
        merged_from.extend(p1.merged_from)  # type: ignore[union-attr]
    if hasattr(p2, "merged_from"):
        merged_from.extend(p2.merged_from)  # type: ignore[union-attr]

    return MergedPlane(
        normal=avg_normal,
        d=d,
        inlier_indices=all_idx,
        inlier_ratio=avg_inlier_ratio,
        residual_std=avg_residual_std,
        centroid=centroid,
        merged_from=merged_from,
    )


def _should_merge(
    p1: FittedPlane | MergedPlane, p2: FittedPlane | MergedPlane
) -> bool:
    angle = _angle_between_normals(p1.normal, p2.normal)
    if angle >= _MAX_NORMAL_ANGLE_DEG:
        return False
    # Check distance of each centroid to the other plane.
    dist_1_to_2 = _plane_plane_dist(p1.normal, p1.d, p2.centroid)
    dist_2_to_1 = _plane_plane_dist(p2.normal, p2.d, p1.centroid)
    return min(dist_1_to_2, dist_2_to_1) < _MAX_CENTROID_DIST_M


def merge_coplanar_facets(
    planes: list[FittedPlane],
) -> list[MergedPlane]:
    """Greedily merge near-coplanar planes.

    Uses a simple O(N²) greedy pass (N is typically ≤ 16).
    Runs until no more merges are possible.
    """
    # Convert to MergedPlane so we can track provenance.
    merged: list[MergedPlane] = [
        MergedPlane(
            normal=p.normal,
            d=p.d,
            inlier_indices=p.inlier_indices,
            inlier_ratio=p.inlier_ratio,
            residual_std=p.residual_std,
            centroid=p.centroid,
            merged_from=[i],
        )
        for i, p in enumerate(planes)
    ]

    changed = True
    while changed:
        changed = False
        n = len(merged)
        for i in range(n):
            for j in range(i + 1, n):
                if _should_merge(merged[i], merged[j]):
                    new_plane = _merge_two(merged[i], merged[j])
                    # Replace i, remove j.
                    merged = [merged[k] for k in range(n) if k not in (i, j)]
                    merged.insert(i, new_plane)
                    changed = True
                    break
            if changed:
                break

    return merged
