# Feature: INTEGRATION — Measurement orchestrator (GeometryJob)

**ID:** F-10 · **Roadmap piece:** F-10 · **Status:** Not started · **Type:** Integration

## Description

This is an **integration feature** — its acceptance is the combined,
end-to-end behavior of the five inputs it composes (F-05 through
F-09). It implements the Rails-side `GeometryJob` running on Solid
Queue per [ADR-008](../adrs/ADR-008-backend-rails-with-python-sidecar.md):
chains the geospatial pipeline stages, composes the VLM detections,
handles the LiDAR-missing fallback path, persists the unified
`Measurement` to PostGIS, and broadcasts status to the web client
over ActionCable.

Why it exists as its own feature: the pipeline track has four parallel
sidecar features plus one Rails-side VLM feature, all converging here.
Without an explicit integration feature, the convergence is invisible
in the plan and integration risk lands silently at the end. With it,
contract drift across the parallel features is caught here, and
end-to-end acceptance criteria force the team to wire things together
rather than declaring victory on isolated pieces.

## How it fits the roadmap

**The first integration node — Wave 3.** On the critical path. The
highest-coordination-risk feature in the project. Unblocks the web
viewer (F-12), PDF (F-13), JSON export (F-14), iOS fusion (F-16),
both stretches (F-17, F-18), and the validation harness (F-19).

## Dependencies (must exist before this starts)

- **F-05 Address & polygon resolver** — produces geocode + polygons.
- **F-06 LiDAR ingest** — produces point array or `LIDAR_MISSING`.
- **F-07 Outline refinement** — produces refined polygon.
- **F-08 Plane fit + measurement** — produces facet list + measurement
  (both LiDAR and fallback endpoints).
- **F-09 VLM feature detection** — produces feature detections.

(F-11 Job submission flow is *not* a dependency: F-10 can be exercised
via a console invocation / spec runner. F-11 adds the production UI
trigger but does not block F-10's acceptance.)

## Unblocks (what waits on this)

- **F-12 Web report viewer** — consumes the persisted `Measurement`.
- **F-13 PDF report** — consumes the persisted `Measurement`.
- **F-14 JSON export** — serializes the persisted `Measurement`.
- **F-16 iOS fusion** — runs after F-10 completes for a job.
- **F-17, F-18 stretches** — consume the persisted `Measurement`.
- **F-19 validation harness** — runs the full pipeline on the test set.

## Acceptance criteria

The acceptance is **end-to-end behavior**, not "each input has an
acceptance test." Specifically:

- **Happy path (LiDAR available):** submitting an address via the
  orchestrator's entry point (a Rails service or a Solid Queue
  `GeometryJob.perform_later`) produces, within 90 seconds:
  - A `Measurement` row in PostGIS containing geocode, parcel
    polygon, building polygon, refined outline, facet list with
    pitch + area + confidence + source, feature detections, total
    area, total perimeter, primary pitch, overall confidence,
    `source: "lidar+imagery"`, provenance metadata (data source
    versions, acquisition dates, model versions).
  - The row's per-facet `source` field is `"lidar+imagery"`; the
    per-feature `source` is `"vlm:gemini-flash-..."`.
  - ActionCable broadcasts status transitions: `pending` →
    `resolving_address` → `fetching_lidar` → `refining_outline` →
    `detecting_features` (parallel) → `fitting_planes` → `ready`.
- **Fallback path (LiDAR missing):** the same submission for an
  address in a 3DEP gap produces a `Measurement` row within 30
  seconds with `source: "imagery_only"`, a lower overall
  confidence, and a `warnings` field containing
  `["lidar_missing: <reason>"]`.
- **Pipeline contract enforcement:** the orchestrator validates
  every cross-service payload against `shared/pipeline_schema.json`;
  schema violations fail the job loudly with a clear error
  (this is the feature that catches contract drift from F-05–F-09).
- **VLM runs in parallel** with the geometric pipeline stages where
  possible (the orchestrator does not serialize unnecessarily).
- **Failure isolation:** if F-09 VLM call fails (timeout, API
  error), the measurement still completes with `features: []` and
  a `warnings` entry; the geometric portion is not affected. The
  reverse — geometric failure with VLM success — fails the whole
  job (no geometry = no measurement).
- **Idempotency:** re-submitting the same address with the same
  `polygon_selection` returns the cached `Measurement` if generated
  within the last hour; otherwise re-runs.
- **End-to-end integration test in CI:** runs against the
  docker-compose stack with mocked external services (Nominatim,
  Regrid, MS Footprints, USGS 3DEP via local fixture COPC files,
  SAM2 local backend, Gemini stubbed), exercises both LiDAR-
  available and LiDAR-missing paths, asserts the resulting
  `Measurement` shape.

## Testing requirements

- **End-to-end integration tests** (in addition to the in-CI test
  above):
  - One LiDAR-available demo address run against the live
    deployment (smoke).
  - One LiDAR-missing address run against the live deployment.
- **Contract-drift test:** intentionally break one pipeline
  feature's response (e.g., remove a required field); the
  orchestrator's schema validation must fail the job with a clear,
  actionable error message naming the offending feature.
- **Failure-isolation test:** stub the VLM to throw; verify the
  measurement completes with `features: []` + warning.
- **Status-broadcast test:** Capybara test confirms ActionCable
  channel receives the expected status transitions in order.
- **Latency test:** end-to-end <120s on a warm-cache LiDAR-available
  fixture address.

## Manual setup required

- **All upstream features (F-05–F-09) deployed** to the same droplet
  via Kamal; this is a coordination point, not a code dependency,
  but the integration test requires it.
- **Real Modal + Gemini credentials in CI** are *not* required —
  the integration test uses local backends and stubs; live
  deployment smoke tests use the real credentials provisioned in
  F-07 and F-09.

## Implementation notes (filled in by the building agent)

> The agent implementing this feature records its implementation
> decisions and rationale here as it builds — chosen libraries/patterns
> within the architecture's constraints, trade-offs made, deviations
> from assumptions and why, and anything the next agent or the
> integrator needs to know. This section starts empty and is owned by
> the builder, not the planner. Cross-cutting discoveries that affect
> other features must also be propagated to ROADMAP.md or the
> architecture doc, not just left here.
