"""ICP alignment + OBJ parsing unit tests (ADR-007 capture fusion).

Drives align_mesh_to_lidar / parse_obj directly against the committed f16
fixtures (a synthetic gable roof + a known rigid offset), so the convergence
acceptance (RMSE < 0.15 m, >= 80% of vertices within 0.1 m) is asserted without
network or Spaces.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from app.fuse_capture.icp import align_mesh_to_lidar, gps_to_utm
from app.fuse_capture.mesh_io import MeshTooLargeError, parse_obj

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "f16"


@pytest.fixture(scope="module")
def lidar_pts() -> np.ndarray:
    return np.load(FIXTURES / "lidar_cloud.npy")[:, :3]


def _mesh(name: str) -> np.ndarray:
    return parse_obj((FIXTURES / name).read_bytes())


class TestConvergence:
    def test_aligns_within_acceptance(self, lidar_pts):
        result = align_mesh_to_lidar(_mesh("arkit_mesh.obj"), lidar_pts)
        assert result.converged is True
        assert result.rmse_m < 0.15, result.rmse_m
        assert result.pct_within_0_1m >= 0.8, result.pct_within_0_1m

    def test_bad_mesh_does_not_converge(self, lidar_pts):
        result = align_mesh_to_lidar(_mesh("arkit_mesh_bad.obj"), lidar_pts)
        assert result.converged is False
        assert result.rmse_m > 0.5, result.rmse_m


class TestGpsSeed:
    def test_gps_to_utm_known_coord(self):
        # Lincoln, NE area (UTM zone 14N = EPSG:32614). Round-trip stays sane.
        easting, northing = gps_to_utm(40.808, -96.706, 32614)
        assert 600_000 < easting < 720_000, easting
        assert 4_500_000 < northing < 4_530_000, northing


class TestParseObj:
    def test_round_trip_minimal(self):
        data = b"# comment\nv 1.0 2.0 3.0\nvn 0 0 1\nv 4 5 6\nf 1 2 3\n"
        pts = parse_obj(data)
        assert pts.shape == (2, 3)
        np.testing.assert_allclose(pts[0], [1.0, 2.0, 3.0])
        np.testing.assert_allclose(pts[1], [4.0, 5.0, 6.0])

    def test_no_vertices_returns_empty(self):
        pts = parse_obj(b"# only comments\nf 1 2 3\n")
        assert pts.shape == (0, 3)

    def test_rejects_oversized_vertex_count(self, monkeypatch):
        monkeypatch.setattr("app.fuse_capture.mesh_io.MAX_VERTICES", 3)
        data = b"\n".join(b"v %d 0 0" % i for i in range(5))
        with pytest.raises(MeshTooLargeError):
            parse_obj(data)
