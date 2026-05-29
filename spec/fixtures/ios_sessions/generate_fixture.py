#!/usr/bin/env python3
"""Deterministic generator for the synthetic iOS capture-bundle fixture.

Emits, under spec/fixtures/ios_sessions/:
  synthetic_house/session.json   -- conforms to shared/ios_session_schema.json
  synthetic_house/arkit_mesh.obj -- 8-vertex flat gable, ARKit-local meters,
                                    offset +0.5m N, +0.3m E from the LiDAR cloud
  synthetic_house/photo_00..07.jpg -- 100x100 solid-color JPEG placeholders
  synthetic_house/depth_00..07.png -- 100x100 16-bit PNG, all pixels = 2000 (2.0m)
  synthetic_house/README.md
  synthetic_house_lidar.npy        -- (N,4) [x, y, z, classification=6] LiDAR cloud,
                                    same house geometry WITHOUT the rigid offset

This is the barrier artifact the ICP fusion workstream builds and tests against.
The deliberate +0.5m N / +0.3m E offset between the ARKit mesh and the LiDAR
cloud is the ICP ground truth the convergence test asserts.

Dependencies: NumPy + Pillow only (pyproj used only to derive the demo GPS
origin from the UTM cloud centroid; a hardcoded fallback keeps it offline-safe).
Run:  cd sidecar && uv run python ../spec/fixtures/ios_sessions/generate_fixture.py
"""
import json
import math
import os

import numpy as np
from PIL import Image

# --- Determinism -----------------------------------------------------------
SEED = 20260528
rng = np.random.default_rng(SEED)

HERE = os.path.dirname(os.path.abspath(__file__))
HOUSE_DIR = os.path.join(HERE, "synthetic_house")
os.makedirs(HOUSE_DIR, exist_ok=True)

# --- Demo address / CRS ----------------------------------------------------
# First real address in sidecar/validation/test_addresses.yaml:
#   "1300 Q St, Lincoln, NE 68508" -> UTM zone 14N -> EPSG:32614
DEMO_ADDRESS = "1300 Q St, Lincoln, NE 68508"
UTM_EPSG = 32614
# Approximate WGS84 location of the demo address (HAE altitude).
ORIGIN_LAT = 40.808
ORIGIN_LON = -96.706
ORIGIN_ALT_HAE_M = 360.0  # WGS84 ellipsoidal height (HAE), NOT MSL.

# Known ICP ground-truth rigid offset applied to the ARKit mesh relative to
# the LiDAR cloud (ENU meters, E=east/x, N=north/y).
OFFSET_EAST_M = 0.3
OFFSET_NORTH_M = 0.5

# --- Deterministic UUIDs (uuid4 shape, fixed) ------------------------------
SESSION_ID = "5e551011-0000-4000-8000-000000000001"
JOB_ID = "10b00000-0000-4000-8000-000000000002"


def gable_house_vertices():
    """8 vertices of a simple rectangular flat-gable roof, ARKit-local meters,
    Y-up gravity-aligned. Footprint 10m (E/x) x 8m (N/y); eave at z=4m, ridge
    at z=6m running along the N axis at the E midline. Returns (8,3) float64.

    Vertices (x=east, y=north, z=up):
      eaves (4 corners at z=4): SW, SE, NE, NW of footprint
      ridge line endpoints (z=6) at x=5 (mid), y=0 and y=8
    """
    return np.array(
        [
            [0.0, 0.0, 4.0],   # 0 eave SW
            [10.0, 0.0, 4.0],  # 1 eave SE
            [10.0, 8.0, 4.0],  # 2 eave NE
            [0.0, 8.0, 4.0],   # 3 eave NW
            [5.0, 0.0, 6.0],   # 4 ridge S
            [5.0, 8.0, 6.0],   # 5 ridge N
            [2.5, 4.0, 5.0],   # 6 west-slope sample point
            [7.5, 4.0, 5.0],   # 7 east-slope sample point
        ],
        dtype=np.float64,
    )


def gable_faces():
    """4 triangular faces (1-based OBJ indices) covering the two roof slopes.

    West slope is the quad SW(1)-NW(4)-ridgeN(6)-ridgeS(5), split into two
    triangles; east slope is the quad SE(2)-NE(3)-ridgeN(6)-ridgeS(5), split
    into two triangles. No degenerate or duplicated faces.
    """
    return [
        (1, 4, 6),  # west slope tri A  (SW eave, NW eave, ridge N)
        (1, 6, 5),  # west slope tri B  (SW eave, ridge N, ridge S)
        (2, 5, 6),  # east slope tri A  (SE eave, ridge S, ridge N)
        (2, 6, 3),  # east slope tri B  (SE eave, ridge N, NE eave)
    ]


def write_obj(path, verts, faces):
    lines = ["# synthetic_house ARKit world mesh (arkit_session_local, meters)"]
    for v in verts:
        lines.append(f"v {v[0]:.6f} {v[1]:.6f} {v[2]:.6f}")
    for f in faces:
        lines.append(f"f {f[0]} {f[1]} {f[2]}")
    with open(path, "w") as fh:
        fh.write("\n".join(lines) + "\n")


def densify_cloud(verts, n_per_face=400):
    """Sample a dense point cloud across the two roof slopes for ICP."""
    # West slope plane through eaves (0,3) and ridge (4,5); east slope through
    # eaves (1,2) and ridge (4,5). Sample barycentric over two big triangles.
    pts = []
    slopes = [
        (verts[0], verts[3], verts[5], verts[4]),  # west quad SW,NW,ridgeN,ridgeS
        (verts[1], verts[2], verts[5], verts[4]),  # east quad SE,NE,ridgeN,ridgeS
    ]
    for a, b, c, d in slopes:
        u = rng.random(n_per_face)
        v = rng.random(n_per_face)
        # bilinear over the quad (a-b edge, a-d edge)
        p = (
            a[None, :] * ((1 - u) * (1 - v))[:, None]
            + b[None, :] * (u * (1 - v))[:, None]
            + c[None, :] * (u * v)[:, None]
            + d[None, :] * ((1 - u) * v)[:, None]
        )
        pts.append(p)
    cloud = np.vstack(pts)
    # small measurement noise (deterministic) to look like real LiDAR
    cloud = cloud + rng.normal(0.0, 0.01, size=cloud.shape)
    return cloud


def row_major_identity_intrinsics():
    # Plausible 100x100 pinhole intrinsics, row-major 3x3.
    fx = fy = 80.0
    cx = cy = 50.0
    return [fx, 0.0, cx, 0.0, fy, cy, 0.0, 0.0, 1.0]


def row_major_extrinsic(capture_index):
    """A deterministic, valid row-major 4x4 world->camera extrinsic.

    Built explicitly row-major (NOT a column-major flatten) to mirror the
    serializer's required transpose discipline. We rotate the camera around
    the vertical (Y, up) axis per capture so the 8 prompts look around the
    house, then translate. The matrix encodes [R | t] with bottom row
    [0,0,0,1] in row-major order.
    """
    theta = (capture_index / 8.0) * 2.0 * math.pi
    c, s = math.cos(theta), math.sin(theta)
    # Rotation about Y axis (row-major 3x3):
    #   [ c 0 s ]
    #   [ 0 1 0 ]
    #   [-s 0 c ]
    tx, ty, tz = 5.0 + 8.0 * c, 1.6, 4.0 + 8.0 * s
    return [
        c, 0.0, s, tx,
        0.0, 1.0, 0.0, ty,
        -s, 0.0, c, tz,
        0.0, 0.0, 0.0, 1.0,
    ]


def quaternion_for(capture_index):
    """Unit quaternion (w,x,y,z) for a yaw rotation about vertical."""
    theta = (capture_index / 8.0) * 2.0 * math.pi
    half = theta / 2.0
    return {
        "quaternion_w": round(math.cos(half), 8),
        "quaternion_x": 0.0,
        "quaternion_y": round(math.sin(half), 8),
        "quaternion_z": 0.0,
        "reference_frame": "xArbitraryZVertical",
    }


PROMPT_LABELS = [
    "front_left_corner",
    "front_facade",
    "front_right_corner",
    "right_facade",
    "back_right_corner",
    "back_facade",
    "back_left_corner",
    "left_facade",
]

# Deterministic per-capture solid colors for the JPEG placeholders.
COLORS = [
    (200, 60, 60), (60, 200, 60), (60, 60, 200), (200, 200, 60),
    (200, 60, 200), (60, 200, 200), (160, 120, 80), (120, 120, 120),
]


def gps_for(index):
    # Tiny deterministic jitter around the origin so the per-capture GPS
    # differs but stays at the same site (HAE altitude).
    dlat = (index - 3.5) * 1e-6
    dlon = (index - 3.5) * 1e-6
    return {
        "latitude": round(ORIGIN_LAT + dlat, 8),
        "longitude": round(ORIGIN_LON + dlon, 8),
        "altitude_m": round(ORIGIN_ALT_HAE_M + (index - 3.5) * 0.05, 4),
        "horizontal_accuracy_m": 4.0,
        "vertical_accuracy_m": 6.0,
    }


def main():
    # 1) Geometry
    verts = gable_house_vertices()
    faces = gable_faces()

    # LiDAR cloud (no rigid offset) -> (N,4) [x,y,z,classification=6 (building)]
    cloud_xyz = densify_cloud(verts)
    classification = np.full((cloud_xyz.shape[0], 1), 6.0, dtype=np.float64)
    cloud = np.hstack([cloud_xyz, classification])
    np.save(os.path.join(HERE, "synthetic_house_lidar.npy"), cloud, allow_pickle=False)

    # ARKit mesh vertices = same house + rigid offset (+0.3m E, +0.5m N).
    offset = np.array([OFFSET_EAST_M, OFFSET_NORTH_M, 0.0], dtype=np.float64)
    arkit_verts = verts + offset
    write_obj(os.path.join(HOUSE_DIR, "arkit_mesh.obj"), arkit_verts, faces)

    # 2) Photo + depth placeholders
    for i in range(8):
        Image.new("RGB", (100, 100), COLORS[i]).save(
            os.path.join(HOUSE_DIR, f"photo_{i:02d}.jpg"), "JPEG", quality=85
        )
        depth = np.full((100, 100), 2000, dtype="<u2")  # 2.0m at depth_scale=1000
        # 16-bit little-endian grayscale PNG via I;16 frombytes (stable across
        # Pillow versions; avoids the deprecated fromarray(mode=...) path).
        Image.frombytes("I;16", (100, 100), depth.tobytes()).save(
            os.path.join(HOUSE_DIR, f"depth_{i:02d}.png")
        )

    # 3) session.json
    captures = []
    for i in range(8):
        captures.append(
            {
                "capture_index": i,
                "prompt_label": PROMPT_LABELS[i],
                "photo_filename": f"photo_{i:02d}.jpg",
                "depth_filename": f"depth_{i:02d}.png",
                "timestamp": f"2026-05-28T14:32:{10 + i:02d}.000Z",
                "gps": gps_for(i),
                "camera_pose": {
                    "intrinsics_row_major": row_major_identity_intrinsics(),
                    "world_to_camera_row_major": row_major_extrinsic(i),
                },
                "attitude": quaternion_for(i),
                "depth_scale": 1000.0,
                "depth_unit": "mm_as_uint16",
                "depth_range_m": [2.0, 2.0],
            }
        )

    manifest = {
        "manifest_version": "1.0.0",
        "session_id": SESSION_ID,
        "job_id": JOB_ID,
        "started_at": "2026-05-28T14:32:00.000Z",
        "ended_at": "2026-05-28T14:33:30.000Z",
        "device_info": {
            "model": "iPhone 15 Pro",
            "model_identifier": "iPhone16,1",
            "os_version": "17.5.1",
            "app_version": "1.0.0",
        },
        "gps_origin": {
            "latitude": ORIGIN_LAT,
            "longitude": ORIGIN_LON,
            "altitude_m": ORIGIN_ALT_HAE_M,
            "horizontal_accuracy_m": 3.5,
            "vertical_accuracy_m": 5.0,
            "timestamp": "2026-05-28T14:32:00.000Z",
        },
        "captures": captures,
        "world_mesh": {
            "filename": "arkit_mesh.obj",
            "format": "obj",
            "coordinate_frame": "arkit_session_local",
            "vertex_count": 8,
            "face_count": 4,
        },
    }

    with open(os.path.join(HOUSE_DIR, "session.json"), "w") as fh:
        json.dump(manifest, fh, indent=2)
        fh.write("\n")

    # 4) README
    with open(os.path.join(HOUSE_DIR, "README.md"), "w") as fh:
        fh.write(README_TEXT)

    print(f"Wrote synthetic fixture to {HOUSE_DIR}")
    print(f"  LiDAR cloud points: {cloud.shape[0]} -> synthetic_house_lidar.npy")
    print(f"  ICP ground-truth offset (ARKit relative to LiDAR): "
          f"+{OFFSET_NORTH_M}m N, +{OFFSET_EAST_M}m E")


README_TEXT = """# synthetic_house — synthetic iOS capture-bundle fixture

**This is a fully synthetic fixture, not a real device capture.** It exists so
the iOS-ingest + ICP-fusion workstream can build and test deterministically
without a Pro iPhone or a live capture. It is the CI acceptance fixture; a real
device-captured bundle (if produced) lives at `../real_capture/` and is a
non-CI validation artifact only.

## What's here

| File | What it is |
|---|---|
| `session.json` | The capture manifest. Conforms to `shared/ios_session_schema.json` (`manifest_version` `1.0.0`). |
| `arkit_mesh.obj` | 8-vertex flat-gable ARKit world mesh, `arkit_session_local` meters. |
| `photo_00.jpg` … `photo_07.jpg` | 100×100 solid-color JPEG placeholders, one per capture prompt. |
| `depth_00.png` … `depth_07.png` | 100×100 16-bit PNG depth maps, all pixels = 2000 (2.0 m at `depth_scale` 1000.0). |
| `../synthetic_house_lidar.npy` | `(N, 4)` `[x, y, z, classification=6]` LiDAR cloud of the same house **without** the rigid offset. |

## Demo GPS origin

GPS origin is the demo address **"1300 Q St, Lincoln, NE 68508"** (the first
real entry in `sidecar/validation/test_addresses.yaml`). UTM zone 14N →
**EPSG:32614**. `gps_origin.altitude_m` is an **HAE** (WGS84 ellipsoidal height)
value of ~360.0 m, per the ADR-007 amendment (HAE, never MSL).

## Known ICP ground-truth offset

`arkit_mesh.obj` is the LiDAR house geometry translated by a known rigid offset:

> **+0.5 m North, +0.3 m East** (no rotation, no Z shift).

The ICP convergence test asserts the aligner recovers this and reaches
RMSE < 0.15 m with ≥ 80% of vertices within 0.1 m. The offset is well inside the
0.5 m coarse capture basin, so point-to-plane ICP converges in few iterations.

## How to regenerate

```bash
cd sidecar && uv run python ../spec/fixtures/ios_sessions/generate_fixture.py
```

The generator is deterministic (seeded RNG), NumPy + Pillow only. Re-running
reproduces byte-stable geometry (modulo JPEG/PNG encoder versions).

## How to replace with a real capture

Drop a real device bundle under `spec/fixtures/ios_sessions/real_capture/`
(its own `session.json` + photos + depths + `arkit_mesh.obj`) and point the
ICP/endpoint tests at it as an additional, non-CI validation fixture. The
synthetic fixture stays the deterministic CI gate.
"""


if __name__ == "__main__":
    main()
