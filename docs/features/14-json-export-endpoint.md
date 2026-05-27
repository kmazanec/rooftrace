# Feature: JSON export endpoint + public-contract schema

**ID:** F-14 · **Roadmap piece:** F-14 · **Status:** Not started

## Description

Exposes the measurement as a versioned, schema-validated JSON
document at `/api/v1/jobs/:id.json` (auth-required for contractor
view; share-token equivalent for public). Per
[ADR-015](../adrs/ADR-015-json-export-schema-versioned.md), the JSON
is treated as a **public contract** — versioned, documented, and
schema-validated in CI — because downstream consumers (insurance
estimating tools, Xactimate, JobNimbus, etc.) will script against it.

## How it fits the roadmap

Wave 3 — after F-10 lands. Off the critical path. Parallel with
F-12 (viewer) and F-13 (PDF).

## Dependencies (must exist before this starts)

- **F-01 Walking skeleton** — deployed Rails.
- **F-02 Pipeline JSON Schema** — internal contract this builds on.
- **F-10 Measurement orchestrator** — produces the `Measurement` to
  serialize.

## Unblocks (what waits on this)

- **None directly** — terminal node. Downstream integrations
  consume it externally.

## Acceptance criteria

- **`shared/json_export.schema.json`** exists per ADR-015 and matches
  the example payload structure in that ADR; declared as JSON Schema
  draft 2020-12; includes `schema_version` field with initial
  value `"1.0.0"`.
- **Top-level fields** match ADR-015: `schema_version`, `job_id`,
  `generated_at`, `address`, `measurement` (with `facets` and
  `features`), `provenance` (data sources + acquisition dates +
  model versions), `artifacts` (`pdf_url`, `model_3d_url`,
  `share_url`), `warnings`.
- **Routes:**
  - `GET /api/v1/jobs/:id.json` (auth-required, contractor view).
  - `GET /r/:share_token.json` (public, token-gated).
- **CORS:** the public share JSON route has CORS headers permissive
  enough for browser-based downstream tools to fetch it (`Access-
  Control-Allow-Origin: *` for the share-token endpoint; locked-down
  for the auth-required endpoint).
- **Serialization:** the Rails serializer
  (`app/serializers/job_export_serializer.rb`) produces a JSON
  document that validates green against
  `shared/json_export.schema.json` for every fixture `Measurement`.
- **Field naming conformance:** verified against industry
  conventions where they exist (Xactimate / EagleView JSON
  examples) — `area_sq_ft`, `pitch_ratio: "6/12"`,
  `pitch_degrees`, `position_lat_lng`. Conventions documented in
  `shared/JSON_EXPORT_CONVENTIONS.md`.
- **Schema changelog:** `shared/JSON_EXPORT_CHANGELOG.md` lists
  v1.0.0 = initial release; bump rules per semver in the ADR.
- **OpenAPI / docs:** brief endpoint documentation at
  `docs/JSON_EXPORT_API.md` linking to the schema and showing one
  example payload.
- **No big binary fields inline:** artifacts (PDF, 3D model) are
  referenced by URL, not base64-embedded.

## Testing requirements

- **Schema-validation test (CI):** one fixture export
  (`spec/fixtures/json_export/sample.json`) validates green against
  `shared/json_export.schema.json`.
- **Round-trip test:** serialize a fixture `Measurement` → validate
  → parse back into a Ruby hash → assert specific fields match the
  source.
- **CORS test:** asserts the public share endpoint emits permissive
  CORS headers; the private endpoint does not.
- **Auth test:** unauthenticated GET to `/api/v1/jobs/:id.json`
  returns 401 (API-style, not 302 — this is for downstream tools
  that don't follow redirects).
- **Schema-breaking-change detector (CI):** the schema validation
  fails if any required v1.x field is removed; prevents accidental
  breaking changes.

## Manual setup required

- **Locate a sample Xactimate or EagleView JSON output** (publicly
  posted on industry forums, vendor docs, or LLM-fabricated +
  human-verified) to use as the field-naming reference. Document
  the source in `JSON_EXPORT_CONVENTIONS.md`.

## Implementation notes (filled in by the building agent)

> The agent implementing this feature records its implementation
> decisions and rationale here as it builds — chosen libraries/patterns
> within the architecture's constraints, trade-offs made, deviations
> from assumptions and why, and anything the next agent or the
> integrator needs to know. This section starts empty and is owned by
> the builder, not the planner. Cross-cutting discoveries that affect
> other features must also be propagated to ROADMAP.md or the
> architecture doc, not just left here.
