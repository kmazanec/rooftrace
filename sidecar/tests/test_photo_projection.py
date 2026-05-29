"""Tests: pinhole projection math (app/render/photo_projection.py, ADR-019).

The load-bearing call is the frame math: a known synthetic camera looking at a
known 3D point must project it to the expected pixel within +-2 px. These tests
are pure numpy — no FastAPI, no storage, no mesh I/O.

Convention (ADR-019, mirrored in the project_photo router):
  - facets live in the ARKit session-local frame (3D, metres).
  - ``intrinsics_3x3`` is the pinhole K = [[fx,0,cx],[0,fy,cy],[0,0,1]].
  - ``world_to_camera_4x4`` is the extrinsic that maps a world point into the
    camera frame (camera looks down +Z, x right, y down — OpenCV convention).
  - a projected vertex is (u, v) in pixels; a vertex behind the camera (z<=0)
    is flagged so a facet straddling the image plane can be culled.
"""

from __future__ import annotations

import math

import numpy as np

from app.render.photo_projection import (
    facets_wgs84_to_arkit,
    project_facets,
    project_points,
)


def _identity_extrinsics() -> list[float]:
    return [
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    ]


def _intrinsics(fx=1000.0, fy=1000.0, cx=512.0, cy=384.0) -> list[float]:
    return [fx, 0.0, cx, 0.0, fy, cy, 0.0, 0.0, 1.0]


class TestProjectPoints:
    def test_point_on_optical_axis_maps_to_principal_point(self):
        # A point straight ahead on +Z projects exactly to (cx, cy).
        pts = np.array([[0.0, 0.0, 5.0]])
        uv, in_front = project_points(pts, _intrinsics(), _identity_extrinsics())
        assert in_front.tolist() == [True]
        assert abs(uv[0, 0] - 512.0) < 1e-6
        assert abs(uv[0, 1] - 384.0) < 1e-6

    def test_known_offset_projects_within_2px(self):
        # x = 0.5 m at z = 5 m, fx = 1000 -> u = cx + fx*x/z = 512 + 100 = 612.
        # y = -0.2 m -> v = cy + fy*y/z = 384 - 40 = 344.
        pts = np.array([[0.5, -0.2, 5.0]])
        uv, _ = project_points(pts, _intrinsics(), _identity_extrinsics())
        assert abs(uv[0, 0] - 612.0) <= 2.0
        assert abs(uv[0, 1] - 344.0) <= 2.0

    def test_translation_extrinsic_shifts_projection(self):
        # Move the camera +1 m along world x (world_to_camera translation = -1 in
        # camera x). A world point at origin then sits at camera x = -1.
        ext = _identity_extrinsics()
        ext[3] = -1.0  # camera-frame x translation
        pts = np.array([[0.0, 0.0, 5.0]])
        uv, in_front = project_points(pts, _intrinsics(), ext)
        # camera point = (-1, 0, 5) -> u = 512 + 1000*(-1)/5 = 312.
        assert in_front.tolist() == [True]
        assert abs(uv[0, 0] - 312.0) <= 2.0

    def test_point_behind_camera_flagged_not_in_front(self):
        pts = np.array([[0.0, 0.0, -3.0]])
        _, in_front = project_points(pts, _intrinsics(), _identity_extrinsics())
        assert in_front.tolist() == [False]

    def test_rotation_extrinsic_yaw(self):
        # 90 deg yaw about camera y: a world point on +X moves onto the optical
        # axis. world_to_camera R for a +90deg rotation maps world +X -> camera +Z.
        theta = math.pi / 2
        c, s = math.cos(theta), math.sin(theta)
        # world_to_camera rotation about y by -theta maps world +X -> camera +Z:
        # R = [[c,0,-s],[0,1,0],[s,0,c]]; for theta=90, R@(5,0,0) = (0,0,5).
        ext = [
            c, 0.0, -s, 0.0,
            0.0, 1.0, 0.0, 0.0,
            s, 0.0, c, 0.0,
            0.0, 0.0, 0.0, 1.0,
        ]
        pts = np.array([[5.0, 0.0, 0.0]])  # world +X at 5 m
        uv, in_front = project_points(pts, _intrinsics(), ext)
        assert in_front.tolist() == [True]
        # camera point = R @ p = (0, 0, 5) -> principal point.
        assert abs(uv[0, 0] - 512.0) <= 2.0
        assert abs(uv[0, 1] - 384.0) <= 2.0


class TestFrameBridging:
    """WGS84 facets -> local UTM -> inverse(arkit_to_utm) -> ARKit-local. The
    highest-risk math: a wrong inverse / UTM order yields a plausible-but-
    misregistered overlay, so this asserts a known transform round-trips exactly."""

    # A pure-translation arkit_to_utm: ARKit origin sits at this UTM anchor.
    _UTM_EPSG = 32614  # UTM 14N
    _ANCHOR_E = 500000.0
    _ANCHOR_N = 4500000.0

    def _translation_transform(self):
        return [
            1.0, 0.0, 0.0, self._ANCHOR_E,
            0.0, 1.0, 0.0, self._ANCHOR_N,
            0.0, 0.0, 1.0, 0.0,
            0.0, 0.0, 0.0, 1.0,
        ]

    def test_wgs84_facet_round_trips_to_expected_arkit_local(self):
        from pyproj import Transformer

        # Pick a WGS84 point inside UTM 14N, convert it to UTM ourselves, then
        # assert facets_wgs84_to_arkit reproduces (UTM - anchor) in ARKit-local.
        lon, lat = -99.0, 40.6
        fwd = Transformer.from_crs("EPSG:4326", f"EPSG:{self._UTM_EPSG}", always_xy=True)
        e, n = fwd.transform(lon, lat)

        facets = [{"facet_id": "F1", "vertices": [[lon, lat, 3.0]]}]
        out = facets_wgs84_to_arkit(facets, self._translation_transform(), self._UTM_EPSG)
        arkit = out[0]["vertices_arkit"][0]

        assert abs(arkit[0] - (e - self._ANCHOR_E)) < 1e-3, arkit
        assert abs(arkit[1] - (n - self._ANCHOR_N)) < 1e-3, arkit
        assert abs(arkit[2] - 3.0) < 1e-6, arkit
        # The original WGS84 vertices are preserved alongside the new frame.
        assert out[0]["vertices"] == facets[0]["vertices"]

    def test_missing_elevation_placed_on_local_z_zero(self):
        out = facets_wgs84_to_arkit(
            [{"facet_id": "F", "vertices": [[-99.0, 40.6]]}],
            self._translation_transform(),
            self._UTM_EPSG,
        )
        assert abs(out[0]["vertices_arkit"][0][2]) < 1e-6


class TestProjectFacets:
    def _square_facet(self):
        # A 1x1 m square at z = 5 m, centred on the optical axis (in ARKit-local
        # coords already, so project_facets does no frame change here).
        return {
            "facet_id": "F1",
            "vertices_arkit": [
                [-0.5, -0.5, 5.0],
                [0.5, -0.5, 5.0],
                [0.5, 0.5, 5.0],
                [-0.5, 0.5, 5.0],
            ],
        }

    def test_square_facet_bbox_within_2px(self):
        facet = self._square_facet()
        projected = project_facets([facet], _intrinsics(), _identity_extrinsics())
        assert len(projected) == 1
        poly = projected[0]
        assert poly["facet_id"] == "F1"
        pts = np.array(poly["points_px"])
        # u = 512 +- 1000*0.5/5 = 512 +- 100 -> [412, 612]; v = 384 +- 100.
        assert abs(pts[:, 0].min() - 412.0) <= 2.0
        assert abs(pts[:, 0].max() - 612.0) <= 2.0
        assert abs(pts[:, 1].min() - 284.0) <= 2.0
        assert abs(pts[:, 1].max() - 484.0) <= 2.0
        assert poly["in_front"] is True

    def test_fully_behind_camera_facet_marked_not_in_front(self):
        facet = {
            "facet_id": "B",
            "vertices_arkit": [
                [-0.5, -0.5, -5.0],
                [0.5, -0.5, -5.0],
                [0.5, 0.5, -5.0],
            ],
        }
        projected = project_facets([facet], _intrinsics(), _identity_extrinsics())
        assert projected[0]["in_front"] is False
