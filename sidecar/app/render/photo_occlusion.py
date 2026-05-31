"""trimesh ray-cast z-buffer occlusion for the photo-overlay stage (ADR-019).

A facet drawn over a photo should not appear to float through walls/chimneys the
ARKit world mesh captured. For each sampled point of a facet we cast a ray from
the camera origin toward that sample (both in the ARKit-local frame); if the
world mesh has a hit NEARER than the sample, that sample is occluded. The facet's
occlusion state is then:

    "visible"   -> no samples occluded (draw solid)
    "partial"   -> some samples occluded (draw dashed/dimmed)
    "occluded"  -> all samples occluded (omit from this photo)

trimesh is used faces-aware (the OBJ vertex-only parser can't drive ray-casts);
``load_world_mesh`` reads an OBJ into (vertices, faces). The intersector is
trimesh's pure-Python/numpy ``RayMeshIntersector`` — no pyrender/OSMesa, so it
runs headless in CI.
"""

from __future__ import annotations

import logging
from typing import Literal

import numpy as np
import numpy.typing as npt

logger = logging.getLogger(__name__)

# Literal type for the three occlusion states produced here and consumed by
# photo_overlay.py and project_photo/router.py.  Using Literal (not str-Enum)
# keeps the wire values unchanged — callers compare with plain string literals.
OcclusionState = Literal["visible", "partial", "occluded"]

# A mesh hit closer than (sample_distance - this slack) counts as an occluder.
# The slack absorbs ray/sample coincidence so a facet sample lying ON the mesh
# surface (the roof itself) doesn't self-occlude.
_DEPTH_SLACK_M = 0.05


def load_world_mesh(data: bytes) -> tuple[npt.NDArray[np.float64], npt.NDArray[np.int64]]:
    """Parse OBJ bytes into (vertices (N,3) float64, faces (M,3) int64).

    Faces-aware (unlike the fusion stage's vertex-only ``parse_obj``) because the
    ray-cast needs triangles. Returns empty arrays for a mesh with no faces.
    """
    import io
    import trimesh

    loaded = trimesh.load(
        file_obj=io.BytesIO(data),
        file_type="obj",
        process=False,
        force="mesh",
    )
    verts = np.asarray(loaded.vertices, dtype=np.float64).reshape(-1, 3)
    faces = np.asarray(loaded.faces, dtype=np.int64).reshape(-1, 3)
    return verts, faces


def classify_facet_occlusion(
    camera_origin: npt.NDArray,
    facet_points_arkit: npt.NDArray,
    mesh_vertices: npt.NDArray,
    mesh_faces: npt.NDArray,
) -> tuple[OcclusionState, float]:
    """Classify a facet's occlusion against the world mesh from the camera.

    ``camera_origin`` and ``facet_points_arkit`` are in the ARKit-local frame.
    Returns ``(state, occluded_fraction)`` where state is "visible"/"partial"/
    "occluded" and occluded_fraction is the share of sampled points the mesh
    occludes. An empty mesh (no faces) is never occluding -> ("visible", 0.0).
    """
    origin = np.asarray(camera_origin, dtype=np.float64).reshape(3)
    samples = np.asarray(facet_points_arkit, dtype=np.float64).reshape(-1, 3)
    if samples.size == 0:
        return "visible", 0.0

    faces = np.asarray(mesh_faces, dtype=np.int64).reshape(-1, 3)
    verts = np.asarray(mesh_vertices, dtype=np.float64).reshape(-1, 3)
    if faces.size == 0 or verts.size == 0:
        return "visible", 0.0

    import trimesh

    mesh = trimesh.Trimesh(vertices=verts, faces=faces, process=False)
    intersector = trimesh.ray.ray_triangle.RayMeshIntersector(mesh)

    directions = samples - origin
    distances = np.linalg.norm(directions, axis=1)
    # Guard a degenerate zero-length ray (sample == origin): treat as visible.
    nonzero = distances > 1e-9
    unit_dirs = np.zeros_like(directions)
    unit_dirs[nonzero] = directions[nonzero] / distances[nonzero][:, None]

    origins = np.broadcast_to(origin, samples.shape)
    # locations of the FIRST hit per ray (None entry => no hit).
    locations, index_ray, _ = intersector.intersects_location(
        origins[nonzero], unit_dirs[nonzero], multiple_hits=False
    )

    occluded = np.zeros(len(samples), dtype=bool)
    if len(locations) > 0:
        hit_dist = np.linalg.norm(locations - origin, axis=1)
        # Map each hit back to its sample index (index_ray indexes the nonzero set).
        nonzero_idx = np.flatnonzero(nonzero)
        sample_indices = nonzero_idx[index_ray]
        mask = hit_dist < distances[sample_indices] - _DEPTH_SLACK_M
        occluded[sample_indices[mask]] = True

    fraction = float(occluded.mean())
    if fraction == 0.0:
        return "visible", 0.0
    if fraction >= 1.0:
        return "occluded", 1.0
    return "partial", fraction
