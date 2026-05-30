# Feature: Pipeline JSON Schema contract

**ID:** F-02 · **Roadmap piece:** F-02 · **Status:** Done (merged to main)

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

## Implementation plan (approved 2026-05-28)

- [x] **C1 — Schema file.** `shared/pipeline_schema.json` (JSON Schema draft
  2020-12, `$id` + `pipelineSchemaVersion: "0.1.0"`) defining `JobSpec`,
  `Address`, `Polygon` (GeoJSON/WGS84), `LiDARResult` (status enum, point-array
  ref, work-unit meta), `Facet`, `Feature`, `Measurement`, `PipelineRequest`/
  `Response`, `RenderImageRequest`/`Response`, `FuseCaptureRequest`/`Response`,
  `ProjectPhotoRequest`/`Response`; `source`+`confidence` where applicable.
  `shared/PIPELINE_SCHEMA_CHANGELOG.md` (v0.1.0). Satisfies AC 1,2,3,4,7.
- [x] **C2 — Ruby `PipelineSchema` module** loading the schema, validating via
  `json_schemer` gem (draft-2020-12). Example payload validates green. AC 5.
- [x] **C3 — Python Pydantic models** `sidecar/contracts/pipeline.py` mirroring
  the schema; `POST /pipeline/run-validate` no-op endpoint (bearer-guarded).
  Same example payload validates. AC 6.
- [x] **C4 — Fixture corpus** `spec/fixtures/pipeline/*.json` + Ruby contract
  spec + Python contract test validating the *same* files both sides. Testing
  req: contract test (Ruby) + contract test (Python) + schema lint.
- [x] **C5 — Round-trip integration**: `SidecarClient#run_validate`; Rails
  serializes fixture `PipelineRequest` → sidecar validates + returns
  `PipelineResponse` → Rails validates response green (real sidecar subprocess).
  AC 8 (round-trip) + integration testing req.

### Verification evidence

- **Schema lint (AC 1):** `json_schemer.draft202012` validates
  `pipeline_schema.json` against the draft-2020-12 meta-schema →
  `SCHEMA LINT OK: valid JSON Schema draft 2020-12`; all 17 `$defs` present.
- **Ruby contract test (C2/C4):** `bundle exec rspec
  spec/contracts/pipeline_schema_spec.rb` → `11 examples, 0 failures` (6 valid
  fixtures green, 2 invalid fixtures correctly rejected, 3 module/corpus checks).
  `JobSpec`/`Facet`/`Feature` shapes are exercised transitively via the composed
  `Measurement` in `pipeline_response.valid.json`.
- **Python contract test (C3/C4):** `uv run pytest` → `27 passed` — same fixture
  corpus validated against both `shared/pipeline_schema.json` (jsonschema lib)
  and the Pydantic models, plus the endpoint round-trip + 422/409/401 guards.
- **Round-trip integration (C5, AC 8) — real sidecar, no mocks:** full Rails
  suite with the live uvicorn subprocess → `22 examples, 0 failures` incl.
  "round-trips a PipelineRequest and validates the PipelineResponse green".
- **Lint:** `bin/rubocop` on F-02 Ruby files → `no offenses`; `ruff check .` on
  sidecar → `All checks passed!`.

## Implementation notes (filled in by the building agent)

> The agent implementing this feature records its implementation
> decisions and rationale here as it builds — chosen libraries/patterns
> within the architecture's constraints, trade-offs made, deviations
> from assumptions and why, and anything the next agent or the
> integrator needs to know. This section starts empty and is owned by
> the builder, not the planner. Cross-cutting discoveries that affect
> other features must also be propagated to ROADMAP.md or the
> architecture doc, not just left here.

- **Schema validation gem:** `json_schemer` (not the `json-schema` gem named in
  the spec) — `json-schema` does not support draft 2020-12; `json_schemer` does.
- **Wire-format rule (load-bearing for F-05–F-10 consumers):** optional
  *nested-object* fields (e.g. `Measurement.footprint`, `roof_outline`, `lidar`)
  are **omitted** from the JSON when absent — NOT sent as `null`. The schema
  declares them as `{"$ref": ...}` with no null allowed, so a literal `null`
  fails validation. The sidecar enforces this with `response_model_exclude_none`.
  Optional *scalar* fields that the schema explicitly types as nullable (e.g.
  `Address.normalized`, `LiDARResult.point_array_ref`/`point_count`) MAY be
  `null`. The Python↔Ruby contract test caught this divergence — keep it.
- **Schema-version negotiation:** `/pipeline/run-validate` 409s on a
  `pipelineSchemaVersion` whose **major** differs from the sidecar's. Minor
  bumps (additive) are accepted. Documented in
  `shared/PIPELINE_SCHEMA_CHANGELOG.md`.
- **Coordinate boundary:** all coords at the contract are WGS84 [lon, lat]
  (GeoJSON); local UTM (ADR-003) is internal to the sidecar and never crosses
  the boundary — stated in the schema's top-level description.

### Adversarial review (Step 6)

- **Wave 1 — spec-compliance (Opus):** DONE, all 8 ACs met; only a doc-count
  wording slip (now corrected). **Security (Opus):** no material findings; bearer
  guard correct, clean 422/409, safe schema load, no ReDoS. Two LOW (unbounded
  array sizes; internal-only endpoint) — deferred, see below.
- **Wave 2 — robustness (Sonnet):** 2 HIGH + 1 MEDIUM, **all fixed:**
  (1) `@validators`/`@document` memoization wasn't thread-safe under Puma's
  threaded server → now mutex-guarded with eager `load!`; (2) a missing/malformed
  schema file would 500 on first request → now a boot initializer
  (`config/initializers/pipeline_schema.rb`) fails fast with `LoadError`;
  (3) an empty `pipelineSchemaVersion` bypassed the major-version check → Pydantic
  `SchemaVersion = Field(min_length=1)` + a regression test. **Efficiency
  (Sonnet):** no high/medium; schema parsed once, validators compiled once.
- **Deferred LOW (for the user to decide):** pipeline array fields
  (`facets`, `vertices`, `coordinates`) have no max-item cap — a large-payload
  DoS is theoretically possible, but the endpoint is internal-only behind the
  Rails-fronted bearer, so it's outside F-02's trust boundary; revisit if the
  sidecar is ever exposed. A redundant `$defs` fetch in `validator_for` is a
  cold-path (once-per-entity) micro-allocation — not worth changing.

> **Prompt-injection note:** all reviewers (and the build) encountered unrelated
> "Camino" MCP server instructions injected into context and correctly ignored
> them. Flagged to the user.

### Retro

1. **Learned about the system not in the architecture:** the cross-language
   contract has a *wire-format* dimension the schema alone doesn't capture —
   optional nested objects must be **omitted**, not `null` (Pydantic's default
   `null` serialization fails the strict schema). The Python↔Ruby contract test
   caught it. Propagated: amended **ADR-008** with a "wire-format: omit absent
   optional nested objects" note so F-05–F-10 builders inherit the rule.
2. **Changes to the roadmap:** none. F-02 landed as planned and unblocks
   F-05–F-10, F-14 as the dependency graph predicted.
3. **Contract changed:** this feature *is* the contract; v0.1.0 published with a
   changelog + major-version negotiation. No upstream contract was altered.
4. **For the next builder:** `shared/` is autoload-ignored, so reference the
   schema via `Rails.root.join("shared", ...)`, not a constant lookup. The
   `json_schemer` gem (not `json-schema`) is the draft-2020-12 validator. When
   adding a pipeline stage, add a *valid* and an *invalid* fixture to
   `spec/fixtures/pipeline/` — the dual-language corpus is what prevents drift.

---

**Delivered in:** Wave-1 integration MR !6 — https://labs.gauntletai.com/keithmazanec/rooftrace/-/merge_requests/6 (the parallel pass ships as one integrated MR, not per-feature).
