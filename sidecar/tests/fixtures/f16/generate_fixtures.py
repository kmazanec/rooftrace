"""Deterministic generator for the fuse-capture (ICP) test fixtures.

Produces three files in this directory:

* ``lidar_cloud.npy`` — a synthetic gable-roof LiDAR cloud, (500, 4) float64
  ``[x, y, z, classification=6]`` in a local UTM-like metric frame.
* ``arkit_mesh.obj`` — the SAME roof, rigidly translated +0.3 m north (and a
  small east shift), well inside the 0.5 m coarse ICP basin. The convergence
  test asserts the aligner recovers this (RMSE < 0.15 m, >= 80% within 0.1 m).
* ``arkit_mesh_bad.obj`` — the roof both rotated 90 deg about the vertical axis
  AND translated far away: the centroid match cannot recover the rotation, so
  the two surfaces never correspond — a guaranteed non-convergence used by the
  failure-isolation test.

Seeded RNG → byte-stable output, so the committed fixtures are reproducible.
Run:  uv run python tests/fixtures/f16/generate_fixtures.py
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent

# Ground-truth offsets.
GOOD_OFFSET = np.array([0.2, 0.3, 0.0])   # east, north, up (m) — inside basin
BAD_OFFSET = np.array([20.0, 0.0, 0.0])   # far translation (compounds the rotation)

# Roof footprint + ridge, centred so the cloud sits at a non-trivial UTM-like
# location (mimicking a cropped public-LiDAR tile in metres).
_BASE = np.array([200.0, 300.0, 50.0])


def _gable_cloud(rng: np.random.Generator, n: int = 500) -> np.ndarray:
    """Two sloped facets meeting at a ridge along the Y axis."""
    half = n // 2
    # Facet extents: 5 m wide (X), 8 m long (Y); ridge at X=0, eaves at X=+-5.
    y = rng.uniform(0.0, 8.0, size=n)
    # Left facet: x in [-5, 0], rises toward the ridge (z grows as x->0).
    xl = rng.uniform(-5.0, 0.0, size=half)
    zl = (xl + 5.0) * 0.5  # 6/12-ish slope
    # Right facet: x in [0, 5].
    xr = rng.uniform(0.0, 5.0, size=n - half)
    zr = (5.0 - xr) * 0.5
    x = np.concatenate([xl, xr])
    z = np.concatenate([zl, zr])
    pts = np.column_stack([x, y[: len(x)], z]) + _BASE
    # Light measurement noise.
    pts += rng.normal(0.0, 0.02, size=pts.shape)
    return pts


def _write_obj(path: Path, vertices: np.ndarray) -> None:
    lines = ["# synthetic fuse-capture test mesh (metres)"]
    for vx, vy, vz in vertices:
        lines.append(f"v {vx:.6f} {vy:.6f} {vz:.6f}")
    path.write_text("\n".join(lines) + "\n")


def main() -> None:
    rng = np.random.default_rng(20260528)
    cloud = _gable_cloud(rng)

    lidar = np.column_stack([cloud, np.full(len(cloud), 6.0)])  # class=6 (building)
    np.save(HERE / "lidar_cloud.npy", lidar)

    _write_obj(HERE / "arkit_mesh.obj", cloud + GOOD_OFFSET)

    # Bad mesh: rotate the cloud 90 deg about the vertical (Z) axis about its own
    # centroid, then translate it away. The centroid seed cancels the
    # translation but cannot undo the rotation (point-to-plane ICP only refines
    # locally), so the gable facets never correspond → non-convergence.
    centroid = cloud.mean(axis=0)
    rot = np.array([[0.0, -1.0, 0.0], [1.0, 0.0, 0.0], [0.0, 0.0, 1.0]])
    rotated = (cloud - centroid) @ rot.T + centroid + BAD_OFFSET
    _write_obj(HERE / "arkit_mesh_bad.obj", rotated)

    print(f"wrote lidar_cloud.npy {lidar.shape}, arkit_mesh.obj, arkit_mesh_bad.obj")


if __name__ == "__main__":
    main()
