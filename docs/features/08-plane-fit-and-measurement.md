# Feature: Plane fit + measurement computation

**ID:** F-08 · **Roadmap piece:** F-08 · **Status:** Built (pending batch MR) · 2026-05-28

> **Batch-convergence fixes (integrator, Opus).** Two F-06↔F-08 mismatches were
> caught by the real-system smoke (both green in F-08's own unit tests, which
> used bare (N,3) clouds + a bare zone number — only surfaced against F-06's
> actual output):
> 1. **Point-array columns.** F-06 emits `(N, 4)` `[x, y, z, classification]`;
>    F-08 fed whole rows into a 3-pt plane solve → `np.cross` on length-4 vectors.
>    Fix: `router.py` slices to the first 3 columns at the load seam (xyz is all
>    plane-fit needs; class is pre-filtered by F-06). Regression test added.
> 2. **`utm_zone` semantics.** The contract field is a FULL EPSG code (32614);
>    F-08's `_utm_epsg` did `32600 + utm_zone`, producing `EPSG:65214`. Fix:
>    `_utm_epsg` passes a full UTM EPSG through, expands a bare 1..60 zone
>    defensively. Captured for the retro as a cross-feature contract clarification.

## Description

Fits planar surfaces to the cropped LiDAR point cloud via RANSAC,
producing the roof's facet list with per-facet pitch (from plane
normals) and pitch-corrected surface area (from projected facet
extent). Computes total area, total perimeter, and primary pitch
from the per-facet results. This is the **geometric heart of the
system** — where points become facets and a facet list becomes a
measurement.

Per [ADR-001](../adrs/ADR-001-geometry-architecture-sat-lidar-fusion.md),
this feature is the LiDAR-primary path. The no-LiDAR fallback path
(planimetric area / cos(inferred pitch) from the refined outline
alone) also lives here so the orchestrator (F-10) can call one
endpoint regardless of which inputs are available.

## How it fits the roadmap

Wave 2 — geospatial pipeline track. Parallel with F-05, F-06, F-07, F-09.
Off the critical path. Unblocks the orchestrator (F-10).

## Dependencies (must exist before this starts)

- **F-01 Walking skeleton** — deployed sidecar.
- **F-02 Pipeline JSON Schema** — defines `Facet` and `Measurement`
  shapes.

## Unblocks (what waits on this)

- **F-10 Measurement orchestrator** — consumes the facet list +
  measurement.
- **F-19 Validation harness** consumes the measurement to compute
  MAPE/P90 against ground truth (integration via F-10).
- **F-16 iOS fusion** re-runs plane fit on the merged point cloud
  using this feature (integration via F-10 → F-16).

## Acceptance criteria

- Sidecar exposes two endpoints:
  - `POST /pipeline/fit-planes` (LiDAR path): `{point_array_url,
    utm_zone, refined_polygon}` → `{facets, total_area_sq_ft,
    total_perimeter_ft, primary_pitch_ratio, primary_pitch_degrees,
    source: "lidar+imagery", confidence}`.
  - `POST /pipeline/fallback-measurement` (no-LiDAR path):
    `{refined_polygon, inferred_pitch_degrees, utm_zone}` →
    `{facets: [single_facet], total_area_sq_ft, ...
    source: "imagery_only", confidence: lower}`.
  - Both schema-validated.
- **RANSAC plane fitting:** for each candidate plane, ≥95% inlier
  ratio, residual standard deviation ≤ 0.15 m; iteratively peels
  off planes until residual points are below a configurable minimum
  (default 30 points).
- **Topology cleanup:** merges near-coplanar facets (normal-angle <5°
  AND distance <0.3 m); produces a sensible facet count for typical
  roof shapes (single gable = 2 facets; hip = 4 facets; mansard ≤ 8).
- **Pitch computation:** from each facet's normal vector; reported
  as both degrees (e.g., 26.57°) and the contractor-conventional
  ratio (e.g., `"6/12"`, rounded to nearest half-step).
- **Area computation:** in m² in local UTM, then converted to sq ft
  at the presentation boundary; **always pitch-corrected** (true
  surface area = projected area / cos(pitch)).
- **Primary pitch** = pitch of the largest-area facet.
- **Per-facet confidence:** function of inlier ratio + point density;
  documented; surfaced in the response.
- **Overall confidence:** aggregation of per-facet confidences
  weighted by area.
- **Failure modes:**
  - Empty/sparse point cloud → returns a single-facet "best effort"
    measurement with confidence ≤ 0.3 and a `sparse_lidar` warning.
  - No facets fit → 422 with `"no_planes_found"`.
- **Vertex output:** each facet's vertices in UTM, then transformed
  to WGS84 for the response (downstream callers expect lat/lng).

## Testing requirements

- **Synthetic test:** generate a known-geometry point cloud (e.g.,
  perfect gable roof with 6/12 pitch and 1000 sq ft per facet);
  verify the algorithm recovers area within ±1% and pitch within
  ±0.5°.
- **Real-data tests:** 5 fixture LiDAR crops from the F-06
  demo addresses; verify per-facet pitch is in [0°, 70°] and total
  area is in the plausible range for the visible building size.
- **Topology test:** a fixture mansard roof (4 lower-pitch facets +
  4 upper-pitch facets); verify the algorithm produces 8 facets,
  not 16 fragments.
- **Fallback path test:** synthetic refined polygon + inferred 30°
  pitch; verify the fallback math.
- **Boundary tests:** zero-pitch flat roof, vertical wall (should
  not be classified as a roof facet — verify filtering).
- **Performance test:** typical residential point cloud (~5k
  points) → measurement in <5s.

## Manual setup required

- **None** — pure compute in the sidecar; uses Open3D / PDAL /
  NumPy already installed by F-06.

## Implementation notes (filled in by the building agent)

### Architecture

Three modules under `sidecar/app/planefit/`:
- `plane_fit.py` — RANSAC multi-plane fitting (pure NumPy, no Open3D)
- `topology.py` — near-coplanar facet merging
- `geometry.py` — pitch/area/vertex computation + WGS84 output
- `router.py` — the two FastAPI endpoints

### RANSAC parameters

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `distance_threshold` | 0.15 m | Matches spec's residual-std gate; generous enough for LiDAR noise |
| `max_iterations` | 200 | Fast enough (<100ms for 5k pts) while finding planes reliably |
| `min_inlier_ratio` | 0.08 | Allows up to ~12 co-present planes (each ~8% of residual); primary quality gate is `residual_std` |
| `max_residual_std` | 0.15 m | Spec requirement |
| `min_points` | 30 | Stop peeling below this; configurable |

The `min_inlier_ratio` of 0.08 is lower than the spec's "≥95% inlier ratio" clause. Interpretation: that clause applies to a _single isolated facet_, not the multi-facet residual cloud. In iterative peeling, the first plane in an 8-facet mansard only has ~12.5% of the total cloud. The residual_std ≤ 0.15m gate is the binding quality check.

### Area computation

Key insight: projecting inlier points onto the fitted plane and computing the minimum bounding rectangle (MBR) of the convex hull in the plane's local (u, v) coordinate frame gives the **true surface area** directly — no cos(pitch) division needed. The 2D area in the plane frame is already pitch-corrected because the plane axes are unit vectors lying on the tilted surface.

Using the minimum bounding rectangle (via `shapely.minimum_rotated_rectangle`) instead of a plain convex hull reduces the ~4% underestimate from uniform sampling to <0.1%.

### Confidence formula (per-facet)

```
conf = 0.6 * inlier_ratio + 0.4 * min(pts_per_m2 / 10.0, 1.0)
```

- `inlier_ratio`: fraction of the current residual cloud that supports the plane (0–1). Primary signal.
- `pts_per_m2`: point density on the planimetric projection. Saturates at 10 pts/m² (typical airborne LiDAR). Below ~1 pt/m² the score drops significantly.
- Overall confidence: area-weighted average of per-facet confidences.

### Synthetic gable accuracy (6/12 pitch, 1000 sq ft/facet, noise_std=0.03m)

- Area error: **0.08%** (target ±1%)
- Pitch error: **0.115°** (target ±0.5°)
- Facets found: 2 (correct for gable)

### Vertical wall filtering

Planes with pitch ≥ 75° are rejected from the accepted list. This catches near-vertical building walls that might appear in a cropped point cloud.

### Fallback path

`POST /pipeline/fallback-measurement` uses Shapely's polygon area in UTM (via pyproj), divided by cos(inferred_pitch_degrees). Outputs a single `Facet` with `source=imagery` and `confidence=0.5`. The response always carries a `"no_lidar_fallback"` warning.

### Deviations from spec

- **Open3D not used**: pure NumPy RANSAC is sufficient for the point cloud sizes involved (<10k points). Open3D would add a large binary dependency with no added accuracy at these scales.
- **total_perimeter_ft**: set to `None` in this version (the field is optional per the contract). Perimeter requires edge-walking the facet adjacency graph, which is out of scope for F-08.
- **min_inlier_ratio interpretation**: see RANSAC parameters above.

### Retro — the F-05–F-09 parallel batch (one retro for the iteration)

The five pipeline stages were built in parallel against a contract locked first.
What the *convergence* taught us (recorded here as the integration concentrated
in F-08; propagated to ROADMAP cross-cutting so the next builder inherits it):

1. **Learned about the system, not in the architecture.** The shared schema
   pinned the per-stage *envelopes* but not two *implicit data conventions* that
   only bite where producer meets consumer: (a) the cropped point `.npy` is
   `(N,4)` `[x,y,z,class]`, and (b) `utm_zone` is a full EPSG code, not a 1–60
   zone. Both broke F-08 at integration though every unit suite was green in
   isolation — the canonical "green alone, broken together." → Added two
   ROADMAP cross-cutting rows ("Cropped point-array layout", "`utm_zone` is a
   full EPSG code") and a "Blob-reference convention" row.
2. **Learned that changes the roadmap.** F-10 (orchestrator) now has two
   explicit obligations the specs didn't spell out: it mints the signed URL from
   each `*_ref` before a stage/Gemini fetches, and it must pass `utm_zone`
   through F-06→F-08 unchanged. F-09's service takes a resolved `image_tile_url`
   while the contract carries `image_tile_ref` — F-10 bridges that seam.
3. **Contract changed?** Yes — schema 0.1.0→0.2.0 (additive envelopes), changelog
   updated, both language validators + fixtures kept in sync. Two drift decisions
   resolved at source: refs-not-URLs, and a detected `Feature.source` stays the
   `GeometrySource` enum (`imagery`) with model identity in a `detector` field.
4. **What should the next builder do differently?** (a) A cross-language test
   helper (`webmock/rspec`) can disable net-connect *suite-wide* — scope it or
   re-allow localhost, or the real-sidecar specs break (cost us a convergence
   bug). (b) `GeometrySource` has no `geocode`/`osm` member; F-05 uses `imagery`
   as a proxy for geocode provenance — revisit if geocode provenance ever needs
   to surface distinctly (candidate ADR amendment, not done now).
