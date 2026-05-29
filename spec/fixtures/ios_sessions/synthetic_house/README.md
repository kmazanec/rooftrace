# synthetic_house — synthetic iOS capture-bundle fixture

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
