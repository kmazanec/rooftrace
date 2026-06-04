# Feature: LiDAR Roof Model Accuracy

**Status:** Done · **Date:** 2026-06-04

## What this delivers (before -> after)

Before: the LiDAR path fits independent RANSAC planes and estimates each facet
mostly from point-cloud extents, so refined outlines and roof topology do not
meaningfully constrain measured area.

After: the LiDAR path builds an explicit roof model from planes, the refined
outline, clipped facet polygons, and topology diagnostics, then derives the
existing facet/area output from that model.

## Requirements & acceptance criteria

1. Given a LiDAR fit request with a refined roof outline, when the sidecar
   computes LiDAR facets, then facet plan-view polygons are constrained to the
   refined outline before area is reported.
2. Given a non-rectangular or clipped roof outline, when a plane's point extent
   would overstate the facet with a minimum bounding rectangle, then the reported
   area uses the outline-clipped roof-model polygon instead.
3. Given adjacent roof planes, when the sidecar builds the model, then it records
   topology diagnostics including plane count, facet count, edge count, and
   model warnings without breaking existing `facets` consumers.
4. Given existing Rails/report/viewer consumers, when the sidecar returns a
   measurement, then required legacy fields (`facets`, `total_area_sq_ft`,
   `primary_pitch_*`, `source`, `confidence`) still validate and render.
5. Given malformed or sparse geometry, when a roof model cannot be built, then
   the sidecar degrades through existing warnings/422 behavior rather than
   returning silently inflated measurements.

## Approach

The first architectural slice keeps the HTTP endpoint and persisted measurement
shape compatible while changing the LiDAR internals:

- Add a `roof_model` module under `sidecar/app/planefit/` that converts merged
  planes plus the refined WGS84 outline into a local UTM roof model.
- Build per-plane plan-view support polygons from projected inlier points,
  clip them to the refined outline, trim overlap, and compute true surface
  area as `clipped_plan_area / cos(pitch)`.
- Keep `Facet` output as the compatibility surface; add an optional
  `roof_model` diagnostic object to `MeasurementGeometry` for contract-visible
  topology without forcing Rails persistence changes.
- Keep the imagery fallback path unchanged in this feature.
- Use additive schema changes only unless a later slice proves a breaking change
  is necessary.

## Build plan

- [x] Slice 1: roof-model unit tests for outline clipping, non-rectangular area,
  and topology diagnostics. Proves acceptance criteria 1, 2, and 3 with focused
  synthetic fixtures.
- [x] Slice 2: implement `roof_model` and route the LiDAR fit path through it,
  keeping fallback behavior unchanged. Proves criteria 1, 2, 4, and 5.
- [x] Slice 3: add optional `roof_model` diagnostics to the Python and JSON
  schema contract plus fixtures. Proves criteria 3 and 4.
- [x] Slice 4: update fusion reuse of plane-fit internals so capture fusion uses
  the same model path where enough outline context exists, or explicitly records
  the compatibility fallback.
- [x] Slice 5: run impacted sidecar tests, contract tests, and Rails client/
  orchestrator specs; fix drift.

## Quality bars

- Security: no new external service or trust boundary. Existing storage-ref and
  schema validation behavior stays in place.
- Non-functional: model construction must stay in-memory and Shapely/NumPy-only;
  typical residential clouds should remain comfortably under the existing
  sidecar timeout.
- Observability: model-level warnings must surface through `warnings` and
  optional diagnostics so suspicious measurements are inspectable.
- Simplicity: prefer additive contract diagnostics and compatibility output
  over a broad persisted measurement redesign in the first pass.

## Decisions, assumptions & blockers

Decisions made:

- Kept `Facet` and `MeasurementGeometry` legacy roll-up fields stable, adding
  optional `roof_model` diagnostics instead of replacing downstream shapes.
- Bumped the pipeline schema to `0.6.0` as an additive minor change.
- Persisted roof-model diagnostics in measurement provenance so the model
  evidence survives the sidecar response.
- Threaded the prior refined outline into capture fusion and used the same roof
  model when available; no-outline fusion remains compatible with the legacy
  plane-to-facet adapter.
- Used clipped support polygons for the first roof-model slice. A more advanced
  concave/alpha-shape boundary estimator remains available if validation shows
  support MBRs clipped to outline still overstate complex partial facets.

Assumptions:

- Existing reports, viewer, PDF, and JSON export should continue consuming
  `facets` without needing immediate UI/schema changes for topology edges.
- The refined roof outline is the best available exterior constraint on the
  LiDAR-primary path; when it is poor, model warnings and confidence should
  surface that rather than silently inventing area.

Deferred / blockers:

- Ridge/valley/eave classification is diagnostic only in this pass; edges are
  detected for adjacency but not yet rendered or exported as first-class roof
  lines.
- The validation ground-truth controls are still required before claiming the
  3% target empirically across real roofs.
