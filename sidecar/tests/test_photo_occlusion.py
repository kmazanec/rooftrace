"""Tests: trimesh ray-cast z-buffer occlusion (app/render/photo_occlusion.py).

Synthetic scene math, no FastAPI / storage. A facet sample is occluded when the
world mesh has a nearer ray hit between the camera origin and that sample. The
acceptance scenarios (ADR-019):
  - a facet in clear view -> 0 occluded samples (state "visible").
  - a facet entirely behind a wall -> all samples occluded (state "occluded";
    the router omits a fully-occluded facet from that photo).
  - a facet partly behind a wall -> some samples occluded (state "partial"; the
    overlay renders it dashed/dimmed).

trimesh is used faces-aware (parse_obj returns verts only); a small box mesh is
built directly so the ray-cast surface is exact and CI-deterministic.
"""

from __future__ import annotations

import numpy as np

from app.render.photo_occlusion import classify_facet_occlusion


def _wall(center_x: float, half_w: float = 5.0, half_h: float = 5.0):
    """A thin axis-aligned quad-as-two-triangles wall in the plane x = center_x,
    spanning y,z in [-half, +half]. Returns (vertices (N,3), faces (M,3))."""
    cx = center_x
    verts = np.array([
        [cx, -half_w, -half_h],
        [cx, half_w, -half_h],
        [cx, half_w, half_h],
        [cx, -half_w, half_h],
    ], dtype=np.float64)
    faces = np.array([[0, 1, 2], [0, 2, 3]], dtype=np.int64)
    return verts, faces


class TestClassifyFacetOcclusion:
    # Camera at the ARKit-local origin, looking down +x (so a wall at x=2 sits
    # between the camera and a facet at x=4).
    _CAM = np.array([0.0, 0.0, 0.0])

    def test_clear_view_is_visible(self):
        # No wall between camera and facet -> nothing occluded.
        verts, faces = _wall(center_x=10.0)  # wall is BEHIND the facet
        facet_pts = np.array([[4.0, 0.0, 0.0], [4.0, 0.5, 0.0], [4.0, -0.5, 0.0]])
        state, occluded_fraction = classify_facet_occlusion(
            self._CAM, facet_pts, verts, faces
        )
        assert state == "visible", (state, occluded_fraction)
        assert occluded_fraction == 0.0

    def test_fully_behind_wall_is_occluded(self):
        verts, faces = _wall(center_x=2.0)  # wall between camera (0) and facet (4)
        facet_pts = np.array([[4.0, 0.0, 0.0], [4.0, 0.5, 0.0], [4.0, -0.5, 0.0]])
        state, occluded_fraction = classify_facet_occlusion(
            self._CAM, facet_pts, verts, faces
        )
        assert state == "occluded", (state, occluded_fraction)
        assert occluded_fraction == 1.0

    def test_partly_behind_wall_is_partial(self):
        # Half-wall covering only +y: a facet spanning +y and -y is half occluded.
        cx = 2.0
        verts = np.array([
            [cx, 0.0, -5.0],
            [cx, 5.0, -5.0],
            [cx, 5.0, 5.0],
            [cx, 0.0, 5.0],
        ], dtype=np.float64)
        faces = np.array([[0, 1, 2], [0, 2, 3]], dtype=np.int64)
        facet_pts = np.array([
            [4.0, 2.0, 0.0],   # behind the half-wall (+y) -> occluded
            [4.0, -2.0, 0.0],  # clear (-y) -> visible
        ])
        state, occluded_fraction = classify_facet_occlusion(
            self._CAM, facet_pts, verts, faces
        )
        assert state == "partial", (state, occluded_fraction)
        assert 0.0 < occluded_fraction < 1.0

    def test_empty_mesh_is_visible(self):
        # No mesh faces -> ray-cast has nothing to hit -> never occluded.
        facet_pts = np.array([[4.0, 0.0, 0.0]])
        state, occluded_fraction = classify_facet_occlusion(
            self._CAM, facet_pts, np.empty((0, 3)), np.empty((0, 3), dtype=np.int64)
        )
        assert state == "visible"
        assert occluded_fraction == 0.0
