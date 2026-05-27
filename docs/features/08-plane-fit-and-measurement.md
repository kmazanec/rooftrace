# Feature: Plane fit + measurement computation

**ID:** F-08 · **Roadmap piece:** F-08 · **Status:** Not started

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

> The agent implementing this feature records its implementation
> decisions and rationale here as it builds — chosen libraries/patterns
> within the architecture's constraints, trade-offs made, deviations
> from assumptions and why, and anything the next agent or the
> integrator needs to know. This section starts empty and is owned by
> the builder, not the planner. Cross-cutting discoveries that affect
> other features must also be propagated to ROADMAP.md or the
> architecture doc, not just left here.
