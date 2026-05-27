# Feature: Pipeline JSON Schema contract

**ID:** F-02 · **Roadmap piece:** F-02 · **Status:** Not started

## Description

Defines `shared/pipeline_schema.json` — the single source of truth for
the request/response shape between Rails and the Python sidecar. Per
[ADR-008](../adrs/ADR-008-backend-rails-with-python-sidecar.md), the
sidecar exposes a small set of pipeline endpoints; this contract
defines exactly what flows across that boundary so the five parallel
pipeline features (F-05 through F-09) can be built without contract
drift.

The contract is **the load-bearing artifact** that makes the
geospatial-pipeline track parallelizable. Without it, the four sidecar
features and the orchestrator would either serialize or merge with
constant contract conflicts.

## How it fits the roadmap

Wave 1 — runs in parallel with F-03 (auth) and F-04 (brand). Lands
before any of F-05–F-09 start. Sits one node off the critical path
but gates the entire pipeline track, so prioritize its completion to
unblock parallelism.

## Dependencies (must exist before this starts)

- **F-01 Walking skeleton** — needs the deployed Rails + sidecar to
  validate the schema in a real round-trip, not just on paper.

## Unblocks (what waits on this)

- **F-05 Address & polygon resolver** — produces `polygons` payload.
- **F-06 LiDAR ingest** — produces `lidar_result` payload.
- **F-07 Outline refinement** — consumes building polygon, produces
  refined polygon.
- **F-08 Plane fit + measurement** — produces `measurement` payload
  (facets, pitch, area).
- **F-09 VLM feature detection** — produces `features` payload (Rails-
  side, consumes same schema).
- **F-10 Measurement orchestrator** — assembles all of the above into
  a unified `Measurement` row.
- **F-14 JSON export** — `shared/json_export.schema.json` (public-
  contract JSON export) sits on top of the same internal types.

## Acceptance criteria

- `shared/pipeline_schema.json` exists and validates as JSON Schema
  draft 2020-12.
- The schema defines at minimum the following entity shapes:
  `JobSpec`, `Address`, `Polygon` (geojson-compatible), `LiDARResult`
  (point array reference + work-unit metadata + status enum
  `LIDAR_AVAILABLE` / `LIDAR_MISSING`), `Facet` (vertices, pitch
  ratio + degrees, area sq ft, source enum, confidence float),
  `Feature` (label enum, bbox_norm, confidence, source, verified
  bool), `Measurement` (composes the above), `PipelineRequest`,
  `PipelineResponse`, `RenderImageRequest`, `RenderImageResponse`,
  `FuseCaptureRequest`, `FuseCaptureResponse`,
  `ProjectPhotoRequest`, `ProjectPhotoResponse`.
- Every type has `source` and `confidence` fields where applicable
  per the COMPANY.md honest-uncertainty rule and
  [ADR-001](../adrs/ADR-001-geometry-architecture-sat-lidar-fusion.md).
- Coordinates are documented as WGS84 (EPSG:4326) at the schema
  boundary; the schema docstrings name where local-UTM is used
  internally per
  [ADR-003](../adrs/ADR-003-lidar-source-usgs-3dep-copc.md).
- **Ruby side:** Rails has a `PipelineSchema` module exposing the
  schema for validation; an example payload validates green via
  `json-schema` gem.
- **Python side:** the sidecar has Pydantic models generated from or
  parallel to the schema (`sidecar/contracts/pipeline.py`); the same
  example payload validates against the Pydantic models.
- A round-trip integration test: Rails serializes a fixture
  `PipelineRequest`, POSTs it to the sidecar's `POST
  /pipeline/run-validate` (a no-op validation endpoint), the sidecar
  validates it green and returns a fixture `PipelineResponse`, Rails
  validates the response green.
- Schema is versioned with a top-level `$id` and `pipelineSchemaVersion`
  field; v0.1.0 = initial release; bumps documented in
  `shared/PIPELINE_SCHEMA_CHANGELOG.md`.

## Testing requirements

- **Contract test (Ruby):** loads a corpus of fixture payloads in
  `spec/fixtures/pipeline/` and validates each against the schema.
- **Contract test (Python):** mirrors the Ruby test against the same
  fixture corpus; this catches divergence between the two-language
  views of the schema.
- **Integration test:** the round-trip described above runs as part
  of CI against the docker-compose sidecar.
- **Schema lint:** confirms the file parses as valid JSON Schema
  draft 2020-12 (use `ajv-cli` or equivalent).

## Manual setup required

- **None.** Pure code + schema work.

## Implementation notes (filled in by the building agent)

> The agent implementing this feature records its implementation
> decisions and rationale here as it builds — chosen libraries/patterns
> within the architecture's constraints, trade-offs made, deviations
> from assumptions and why, and anything the next agent or the
> integrator needs to know. This section starts empty and is owned by
> the builder, not the planner. Cross-cutting discoveries that affect
> other features must also be propagated to ROADMAP.md or the
> architecture doc, not just left here.
