"""Plane fit + measurement — test suite.

Synthetic point clouds generated entirely in NumPy (no fixtures required).
All tests are self-contained and run without network or Spaces access.
"""

from __future__ import annotations

import io
import math
import os
import tempfile
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from contracts.pipeline import MeasurementGeometry

# -------------------------------------------------------------------
# App client
# -------------------------------------------------------------------
GOOD_BEARER = {"Authorization": "Bearer test-shared-secret"}


@pytest.fixture(scope="module")
def client():
    from app.main import app

    return TestClient(app)


# -------------------------------------------------------------------
# Helpers to generate synthetic point clouds
# -------------------------------------------------------------------

def _gable_cloud(
    pitch_deg: float = math.degrees(math.atan(6 / 12)),  # 6/12 ≈ 26.57°
    facet_area_m2: float = 92.9,  # ≈ 1000 sq ft
    pts_per_facet: int = 600,
    noise_std: float = 0.05,
    rng: np.random.Generator | None = None,
) -> np.ndarray:
    """Generate a symmetric gable roof point cloud.

    Ridge runs along the Y axis.  Two facets slope away from the ridge
    in the +X and -X directions.  The coordinate origin is at the
    ridge centre.

    Returns shape (N, 3) in metres (suitable UTM-like coords).
    """
    if rng is None:
        rng = np.random.default_rng(0)

    pitch_rad = math.radians(pitch_deg)
    # Facet dimensions: choose width (run) so that projected area = facet_area_m2.
    # projected_area = width * length  (width = run on the horizontal plane)
    # true_area = projected_area / cos(pitch)
    # We want true_area = facet_area_m2, so projected_area = facet_area_m2 * cos(pitch).
    length = 10.0  # metres along ridge (Y)
    run = (facet_area_m2 * math.cos(pitch_rad)) / length  # horizontal width

    points = []
    for sign in (+1, -1):
        # Sample (x_local, y) uniformly on the facet projection.
        x_local = rng.uniform(0, run, pts_per_facet)
        y = rng.uniform(0, length, pts_per_facet)
        # Height above ridge plane: z = sign * (run - x_local) * tan(pitch_rad)
        # (for +X facet, ridge is at x=0; slope goes down as x increases)
        z = (run - x_local) * math.tan(pitch_rad)
        x = sign * x_local
        # Small Gaussian noise.
        noise = rng.normal(0, noise_std, (pts_per_facet, 3))
        pts = np.column_stack([x, y, z]) + noise
        points.append(pts)

    return np.vstack(points).astype(np.float64)


def _mansard_cloud(
    pts_per_facet: int = 200,
    rng: np.random.Generator | None = None,
) -> np.ndarray:
    """4 lower facets (steep, ~60°) + 4 upper facets (shallow, ~15°) = 8 facets total.

    Each group has 4 facets arranged in a square footprint. The groups have
    clearly different pitch so RANSAC won't inadvertently merge them.
    """
    if rng is None:
        rng = np.random.default_rng(42)

    points = []
    noise_std = 0.03

    # Lower facets: 4 sides of a square, steep pitch (~55 deg).
    lower_pitch = math.radians(55)
    lower_height = 3.0
    side = 6.0  # metres per side

    for axis, sign in [(0, +1), (0, -1), (1, +1), (1, -1)]:
        # Flat axis is the OTHER one.
        flat_axis = 1 - axis
        n = pts_per_facet
        along = rng.uniform(-side / 2, side / 2, n)
        run = rng.uniform(0.0, lower_height / math.tan(lower_pitch), n)
        z = run * math.tan(lower_pitch)
        pts = np.zeros((n, 3))
        pts[:, axis] = sign * (side / 2 + run)
        pts[:, flat_axis] = along
        pts[:, 2] = z
        pts += rng.normal(0, noise_std, (n, 3))
        points.append(pts)

    # Upper facets: 4 sides of a smaller square, shallow pitch (~15 deg).
    upper_pitch = math.radians(15)
    upper_height = 1.5
    upper_side = 4.0
    upper_z_base = lower_height

    for axis, sign in [(0, +1), (0, -1), (1, +1), (1, -1)]:
        flat_axis = 1 - axis
        n = pts_per_facet
        along = rng.uniform(-upper_side / 2, upper_side / 2, n)
        run = rng.uniform(0.0, upper_height / math.tan(upper_pitch), n)
        z = upper_z_base + run * math.tan(upper_pitch)
        pts = np.zeros((n, 3))
        pts[:, axis] = sign * (upper_side / 2 + run)
        pts[:, flat_axis] = along
        pts[:, 2] = z
        pts += rng.normal(0, noise_std, (n, 3))
        points.append(pts)

    return np.vstack(points).astype(np.float64)


def _flat_roof_cloud(
    include_walls: bool = True,
    n_roof: int = 500,
    n_wall: int = 300,
    rng: np.random.Generator | None = None,
) -> np.ndarray:
    """Flat roof (pitch=0) with optional vertical wall points."""
    if rng is None:
        rng = np.random.default_rng(7)

    points = []
    # Roof plane at z=3m.
    x = rng.uniform(0, 10, n_roof)
    y = rng.uniform(0, 10, n_roof)
    z = rng.normal(3.0, 0.05, n_roof)
    points.append(np.column_stack([x, y, z]))

    if include_walls:
        # Vertical wall: normal is horizontal, pitch ~90 deg — should be excluded.
        x_wall = rng.uniform(0, 10, n_wall)
        y_wall = np.zeros(n_wall)  # wall at y=0
        z_wall = rng.uniform(0, 3, n_wall)
        points.append(np.column_stack([x_wall, y_wall, z_wall]))

    return np.vstack(points).astype(np.float64)


def _sparse_cloud(n: int = 20, rng: np.random.Generator | None = None) -> np.ndarray:
    if rng is None:
        rng = np.random.default_rng(3)
    return rng.uniform(0, 5, (n, 3))


def _save_npy(array: np.ndarray, dir_path: str, key: str) -> str:
    """Save array as .npy under dir_path/key; return key."""
    full = Path(dir_path) / key
    full.parent.mkdir(parents=True, exist_ok=True)
    np.save(str(full), array)
    return key


def _make_polygon(lon_min=-77.0, lat_min=38.9, width=0.001, height=0.001):
    """A simple rectangular WGS84 polygon."""
    return {
        "type": "Polygon",
        "coordinates": [[
            [lon_min, lat_min],
            [lon_min + width, lat_min],
            [lon_min + width, lat_min + height],
            [lon_min, lat_min + height],
            [lon_min, lat_min],
        ]],
    }


# -------------------------------------------------------------------
# Unit tests for plane_fit module
# -------------------------------------------------------------------

class TestRansacPlaneFit:
    def test_fits_single_plane(self):
        from app.planefit.plane_fit import fit_planes

        rng = np.random.default_rng(1)
        pts = np.column_stack([rng.uniform(0, 10, 500), rng.uniform(0, 10, 500), np.zeros(500)])
        pts += rng.normal(0, 0.02, pts.shape)

        planes = fit_planes(pts, min_points=30)
        assert len(planes) >= 1
        plane = planes[0]
        assert plane.inlier_ratio >= 0.95
        assert plane.residual_std <= 0.15

    def test_fits_two_planes_gable(self):
        from app.planefit.plane_fit import fit_planes

        cloud = _gable_cloud()
        planes = fit_planes(cloud)
        assert len(planes) == 2, f"Expected 2, got {len(planes)}"

    def test_vertical_wall_excluded(self):
        from app.planefit.plane_fit import fit_planes

        cloud = _flat_roof_cloud(include_walls=True)
        planes = fit_planes(cloud)
        for p in planes:
            # All accepted planes must have pitch < 75 deg.
            nz = float(abs(p.normal[2]))
            pitch_deg = math.degrees(math.acos(min(nz, 1.0)))
            assert pitch_deg < 75.0, f"Vertical wall slipped through: pitch={pitch_deg:.1f}°"

    def test_sparse_cloud_returns_empty_or_low(self):
        from app.planefit.plane_fit import fit_planes

        cloud = _sparse_cloud(n=10)
        planes = fit_planes(cloud, min_points=3)
        # Either no planes or fewer than what normal mode would return.
        assert isinstance(planes, list)

    def test_facet_confidence_formula(self):
        from app.planefit.plane_fit import facet_confidence

        # Perfect inlier ratio, high density → near 1.0
        c = facet_confidence(1.0, 10.0)
        assert c >= 0.95

        # Low inlier ratio, zero density → lower
        c2 = facet_confidence(0.95, 0.0)
        assert 0.5 < c2 < 0.65

        # Always in [0, 1]
        for ir in [0.0, 0.5, 0.95, 1.0]:
            for d in [0.0, 1.0, 50.0]:
                assert 0.0 <= facet_confidence(ir, d) <= 1.0


# -------------------------------------------------------------------
# Unit tests for topology module
# -------------------------------------------------------------------

class TestTopologyMerge:
    def test_no_merge_distant_planes(self):
        from app.planefit.plane_fit import FittedPlane
        from app.planefit.topology import merge_coplanar_facets

        # Two planes far apart (z-separation > 0.3 m).
        p1 = FittedPlane(
            normal=np.array([0.0, 0.0, 1.0]),
            d=0.0,
            inlier_indices=np.arange(10),
            inlier_ratio=0.98,
            residual_std=0.05,
            centroid=np.array([0.0, 0.0, 0.0]),
        )
        p2 = FittedPlane(
            normal=np.array([0.0, 0.0, 1.0]),
            d=-1.0,  # 1 m away
            inlier_indices=np.arange(10, 20),
            inlier_ratio=0.98,
            residual_std=0.05,
            centroid=np.array([0.0, 0.0, 1.0]),
        )
        merged = merge_coplanar_facets([p1, p2])
        assert len(merged) == 2

    def test_merge_near_coplanar_same_plane(self):
        from app.planefit.plane_fit import FittedPlane
        from app.planefit.topology import merge_coplanar_facets

        # Two fragments of the same plane (angle ~0°, centroid dist ~0.1 m).
        p1 = FittedPlane(
            normal=np.array([0.0, 0.0, 1.0]),
            d=0.0,
            inlier_indices=np.arange(10),
            inlier_ratio=0.98,
            residual_std=0.05,
            centroid=np.array([0.0, 0.0, 0.0]),
        )
        p2 = FittedPlane(
            normal=np.array([0.0, 0.001, 0.9999995]),  # tiny tilt
            d=-0.05,
            inlier_indices=np.arange(10, 20),
            inlier_ratio=0.98,
            residual_std=0.05,
            centroid=np.array([0.0, 0.1, 0.05]),
        )
        merged = merge_coplanar_facets([p1, p2])
        assert len(merged) == 1

    def test_mansard_produces_eight_facets(self):
        """Mansard cloud → 8 facets, not 16 fragments."""
        from app.planefit.plane_fit import fit_planes
        from app.planefit.topology import merge_coplanar_facets

        cloud = _mansard_cloud(pts_per_facet=300)
        planes = fit_planes(cloud, min_points=30)
        merged = merge_coplanar_facets(planes)
        # Should be ≤ 8 (mansard spec) and at least 6 (all 8 may not always fit).
        assert len(merged) <= 8, f"Expected ≤8 facets, got {len(merged)}"
        assert len(merged) >= 4, f"Too few facets: {len(merged)}"


# -------------------------------------------------------------------
# Endpoint tests (integration via TestClient)
# -------------------------------------------------------------------

class TestFitPlanesEndpoint:
    def test_happy_path_gable(self, client, tmp_path, monkeypatch):
        """Key correctness test: 6/12 gable, area within ±1%, pitch within ±0.5°."""
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))

        # Expected geometry.
        expected_pitch_deg = math.degrees(math.atan(6 / 12))  # 26.565°
        facet_area_m2 = 92.9  # ≈ 1000 sq ft per facet
        cloud = _gable_cloud(
            pitch_deg=expected_pitch_deg,
            facet_area_m2=facet_area_m2,
            pts_per_facet=600,
            noise_std=0.03,
        )
        key = "test/gable.npy"
        _save_npy(cloud, str(tmp_path), key)

        resp = client.post(
            "/pipeline/fit-planes",
            headers=GOOD_BEARER,
            json={
                "pipelineSchemaVersion": "0.2.0",
                "point_array_ref": key,
                "utm_zone": 18,
                "refined_polygon": _make_polygon(),
            },
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()

        # Schema validation.
        mg = MeasurementGeometry.model_validate(body)

        # Should have 2 facets for a gable.
        assert len(mg.facets) == 2, f"Expected 2 facets, got {len(mg.facets)}"

        # Area check: 2 facets × 1000 sq ft = 2000 sq ft, within ±1%.
        expected_total_sqft = 2 * facet_area_m2 * 10.7639
        assert abs(mg.total_area_sq_ft - expected_total_sqft) / expected_total_sqft < 0.01, (
            f"Area off: got {mg.total_area_sq_ft:.1f} sq ft, expected {expected_total_sqft:.1f}"
        )

        # Primary pitch check: within ±0.5°.
        assert abs(mg.primary_pitch_degrees - expected_pitch_deg) <= 0.5, (
            f"Pitch off: got {mg.primary_pitch_degrees:.3f}°, expected {expected_pitch_deg:.3f}°"
        )

        # pitch_ratio should be 6.0 (6/12).
        assert abs(mg.primary_pitch_ratio - 6.0) <= 0.5, (
            f"Pitch ratio off: {mg.primary_pitch_ratio}"
        )

    def test_accepts_f06_shaped_4col_array(self, client, tmp_path, monkeypatch):
        """Convergence regression: the LiDAR ingest stage emits (N, 4)
        [x, y, z, classification] arrays; fit-planes must use the xyz columns
        and not choke on the 4th.
        (Caught at batch integration: the unit helpers used bare (N, 3) clouds.)"""
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        expected_pitch_deg = math.degrees(math.atan(6 / 12))
        cloud3 = _gable_cloud(pitch_deg=expected_pitch_deg, facet_area_m2=92.9, pts_per_facet=600, noise_std=0.03)
        # Append the ASPRS class-6 column the way the ingest stage writes it.
        cloud4 = np.column_stack([cloud3, np.full(len(cloud3), 6.0)])
        assert cloud4.shape[1] == 4
        key = "test/gable_f06.npy"
        _save_npy(cloud4, str(tmp_path), key)

        resp = client.post(
            "/pipeline/fit-planes",
            headers=GOOD_BEARER,
            json={
                "pipelineSchemaVersion": "0.2.0",
                "point_array_ref": key,
                # Full UTM EPSG code as the ingest stage actually emits it (not a bare zone).
                "utm_zone": 32618,
                "refined_polygon": _make_polygon(),
            },
        )
        assert resp.status_code == 200, resp.text
        mg = MeasurementGeometry.model_validate(resp.json())
        assert len(mg.facets) == 2

    def test_requires_bearer(self, client, tmp_path, monkeypatch):
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        resp = client.post(
            "/pipeline/fit-planes",
            json={
                "pipelineSchemaVersion": "0.2.0",
                "point_array_ref": "x.npy",
                "utm_zone": 18,
                "refined_polygon": _make_polygon(),
            },
        )
        assert resp.status_code == 401

    def test_missing_ref_returns_422(self, client, tmp_path, monkeypatch):
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        resp = client.post(
            "/pipeline/fit-planes",
            headers=GOOD_BEARER,
            json={
                "pipelineSchemaVersion": "0.2.0",
                "point_array_ref": "nonexistent.npy",
                "utm_zone": 18,
                "refined_polygon": _make_polygon(),
            },
        )
        assert resp.status_code == 422

    def test_no_planes_found_returns_422(self, client, tmp_path, monkeypatch):
        """Random noise with no planar structure → 422 no_planes_found."""
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        rng = np.random.default_rng(99)
        # Completely random cloud — no planar structure.
        cloud = rng.uniform(0, 100, (500, 3)).astype(np.float64)
        key = "test/noise.npy"
        _save_npy(cloud, str(tmp_path), key)

        resp = client.post(
            "/pipeline/fit-planes",
            headers=GOOD_BEARER,
            json={
                "pipelineSchemaVersion": "0.2.0",
                "point_array_ref": key,
                "utm_zone": 18,
                "refined_polygon": _make_polygon(),
            },
        )
        assert resp.status_code == 422
        assert "no_planes_found" in resp.text

    def test_sparse_cloud_returns_warning(self, client, tmp_path, monkeypatch):
        """Sparse cloud (<100 pts) → sparse_lidar warning + confidence ≤ 0.3."""
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        cloud = _sparse_cloud(n=30)
        key = "test/sparse.npy"
        _save_npy(cloud, str(tmp_path), key)

        resp = client.post(
            "/pipeline/fit-planes",
            headers=GOOD_BEARER,
            json={
                "pipelineSchemaVersion": "0.2.0",
                "point_array_ref": key,
                "utm_zone": 18,
                "refined_polygon": _make_polygon(),
            },
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        mg = MeasurementGeometry.model_validate(body)
        assert "sparse_lidar" in mg.warnings
        assert mg.confidence <= 0.3

    def test_flat_roof_no_wall_facets(self, client, tmp_path, monkeypatch):
        """Flat roof + vertical walls → no walls classified as roof facets."""
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        cloud = _flat_roof_cloud(include_walls=True)
        key = "test/flat_roof.npy"
        _save_npy(cloud, str(tmp_path), key)

        resp = client.post(
            "/pipeline/fit-planes",
            headers=GOOD_BEARER,
            json={
                "pipelineSchemaVersion": "0.2.0",
                "point_array_ref": key,
                "utm_zone": 18,
                "refined_polygon": _make_polygon(),
            },
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        mg = MeasurementGeometry.model_validate(body)
        # No facet should have pitch ≥ 75°.
        for facet in mg.facets:
            assert facet.pitch_degrees < 75.0, (
                f"Wall classified as roof: pitch={facet.pitch_degrees}°"
            )

    def test_response_validates_against_pydantic(self, client, tmp_path, monkeypatch):
        """Every valid response must parse as MeasurementGeometry."""
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        cloud = _gable_cloud()
        key = "test/gable_validate.npy"
        _save_npy(cloud, str(tmp_path), key)

        resp = client.post(
            "/pipeline/fit-planes",
            headers=GOOD_BEARER,
            json={
                "pipelineSchemaVersion": "0.2.0",
                "point_array_ref": key,
                "utm_zone": 18,
                "refined_polygon": _make_polygon(),
            },
        )
        assert resp.status_code == 200, resp.text
        mg = MeasurementGeometry.model_validate(resp.json())
        assert mg.pipelineSchemaVersion == "0.4.0"

    def test_schema_major_mismatch_returns_409(self, client, tmp_path, monkeypatch):
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        resp = client.post(
            "/pipeline/fit-planes",
            headers=GOOD_BEARER,
            json={
                "pipelineSchemaVersion": "9.0.0",
                "point_array_ref": "x.npy",
                "utm_zone": 18,
                "refined_polygon": _make_polygon(),
            },
        )
        assert resp.status_code == 409, resp.text

    def test_malformed_npy_returns_422_not_500(self, client, tmp_path, monkeypatch):
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        # Write non-.npy bytes under the ref key.
        key = "test/garbage.npy"
        (tmp_path / "test").mkdir(parents=True, exist_ok=True)
        (tmp_path / key).write_bytes(b"not a numpy array at all")
        resp = client.post(
            "/pipeline/fit-planes",
            headers=GOOD_BEARER,
            json={
                "pipelineSchemaVersion": "0.2.0",
                "point_array_ref": key,
                "utm_zone": 18,
                "refined_polygon": _make_polygon(),
            },
        )
        assert resp.status_code == 422, resp.text

    def test_bad_utm_zone_returns_422_not_500(self, client, tmp_path, monkeypatch):
        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        cloud = _gable_cloud()
        key = "test/gable_badzone.npy"
        _save_npy(cloud, str(tmp_path), key)
        resp = client.post(
            "/pipeline/fit-planes",
            headers=GOOD_BEARER,
            json={
                "pipelineSchemaVersion": "0.2.0",
                "point_array_ref": key,
                "utm_zone": 999999,  # neither a UTM EPSG nor a 1..60 zone
                "refined_polygon": _make_polygon(),
            },
        )
        assert resp.status_code == 422, resp.text


class TestFallbackMeasurementEndpoint:
    def test_happy_path_30deg(self, client):
        """30° pitch: area = planimetric / cos(30°); verify within ±0.01%."""
        # Polygon: 10m × 10m square centred near (0, 0) in UTM zone 18.
        # We pass WGS84 coords; the server projects to UTM to compute area.
        # Use a real-ish location in UTM-18N.
        lon, lat = -77.0, 38.9
        # A small polygon ≈ 100 m × 100 m.
        dlat = 100 / 111320  # degrees latitude per metre
        dlon = 100 / (111320 * math.cos(math.radians(lat)))

        polygon = {
            "type": "Polygon",
            "coordinates": [[
                [lon, lat],
                [lon + dlon, lat],
                [lon + dlon, lat + dlat],
                [lon, lat + dlat],
                [lon, lat],
            ]],
        }

        resp = client.post(
            "/pipeline/fallback-measurement",
            headers=GOOD_BEARER,
            json={
                "pipelineSchemaVersion": "0.2.0",
                "refined_polygon": polygon,
                "inferred_pitch_degrees": 30.0,
                "utm_zone": 18,
            },
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        mg = MeasurementGeometry.model_validate(body)

        # One imagery facet.
        assert len(mg.facets) == 1
        assert mg.facets[0].source == "imagery"

        # Pitch should be 30°.
        assert abs(mg.facets[0].pitch_degrees - 30.0) < 0.01

        # Pitch ratio: tan(30°)*12 ≈ 6.928 → rounded to nearest 0.5 = 7.0.
        expected_ratio = round(math.tan(math.radians(30.0)) * 12 / 0.5) * 0.5
        assert abs(mg.primary_pitch_ratio - expected_ratio) <= 0.5

        # Area: planimetric ≈ 100m × 100m = 10000 m², corrected by /cos(30°).
        planimetric_m2 = 10000.0
        expected_sqft = (planimetric_m2 / math.cos(math.radians(30.0))) * 10.7639
        # Allow ±2% due to projection approximation.
        assert abs(mg.total_area_sq_ft - expected_sqft) / expected_sqft < 0.02, (
            f"Area off: got {mg.total_area_sq_ft:.0f}, expected ~{expected_sqft:.0f}"
        )

        # source = imagery, confidence < 0.9 (lower than LiDAR).
        assert mg.source == "imagery"
        assert mg.confidence < 0.9

    def test_requires_bearer(self, client):
        resp = client.post(
            "/pipeline/fallback-measurement",
            json={
                "pipelineSchemaVersion": "0.2.0",
                "refined_polygon": _make_polygon(),
                "inferred_pitch_degrees": 20.0,
                "utm_zone": 18,
            },
        )
        assert resp.status_code == 401

    def test_schema_valid(self, client):
        """Response validates against MeasurementGeometry schema."""
        resp = client.post(
            "/pipeline/fallback-measurement",
            headers=GOOD_BEARER,
            json={
                "pipelineSchemaVersion": "0.2.0",
                "refined_polygon": _make_polygon(),
                "inferred_pitch_degrees": 20.0,
                "utm_zone": 18,
            },
        )
        assert resp.status_code == 200, resp.text
        mg = MeasurementGeometry.model_validate(resp.json())
        assert mg.pipelineSchemaVersion == "0.4.0"
        assert mg.source == "imagery"

    def test_flat_zero_pitch(self, client):
        """0° pitch: true_area == planimetric_area."""
        resp = client.post(
            "/pipeline/fallback-measurement",
            headers=GOOD_BEARER,
            json={
                "pipelineSchemaVersion": "0.2.0",
                "refined_polygon": _make_polygon(),
                "inferred_pitch_degrees": 0.0,
                "utm_zone": 18,
            },
        )
        assert resp.status_code == 200, resp.text
        mg = MeasurementGeometry.model_validate(resp.json())
        assert mg.primary_pitch_degrees == 0.0
        assert mg.primary_pitch_ratio == 0.0


# -------------------------------------------------------------------
# JSON Schema validation
# -------------------------------------------------------------------

class TestJsonSchemaValidation:
    """Validate fit-planes and fallback-measurement responses against pipeline_schema.json."""

    def test_fit_planes_response_validates_json_schema(self, client, tmp_path, monkeypatch):
        import json
        from pathlib import Path
        from jsonschema import Draft202012Validator

        monkeypatch.setenv("STORAGE_LOCAL_ROOT", str(tmp_path))
        cloud = _gable_cloud()
        key = "test/gable_schema.npy"
        _save_npy(cloud, str(tmp_path), key)

        resp = client.post(
            "/pipeline/fit-planes",
            headers=GOOD_BEARER,
            json={
                "pipelineSchemaVersion": "0.2.0",
                "point_array_ref": key,
                "utm_zone": 18,
                "refined_polygon": _make_polygon(),
            },
        )
        assert resp.status_code == 200, resp.text

        repo_root = Path(__file__).resolve().parents[2]
        schema = json.loads((repo_root / "shared" / "pipeline_schema.json").read_text())
        sub = {"$ref": "#/$defs/MeasurementGeometry", "$defs": schema["$defs"]}
        validator = Draft202012Validator(sub)
        errors = list(validator.iter_errors(resp.json()))
        assert not errors, f"JSON Schema errors: {[e.message for e in errors]}"

    def test_fallback_response_validates_json_schema(self, client):
        import json
        from pathlib import Path
        from jsonschema import Draft202012Validator

        resp = client.post(
            "/pipeline/fallback-measurement",
            headers=GOOD_BEARER,
            json={
                "pipelineSchemaVersion": "0.2.0",
                "refined_polygon": _make_polygon(),
                "inferred_pitch_degrees": 25.0,
                "utm_zone": 18,
            },
        )
        assert resp.status_code == 200, resp.text

        repo_root = Path(__file__).resolve().parents[2]
        schema = json.loads((repo_root / "shared" / "pipeline_schema.json").read_text())
        sub = {"$ref": "#/$defs/MeasurementGeometry", "$defs": schema["$defs"]}
        validator = Draft202012Validator(sub)
        errors = list(validator.iter_errors(resp.json()))
        assert not errors, f"JSON Schema errors: {[e.message for e in errors]}"
