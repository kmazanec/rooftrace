# Feature: JSON export endpoint + public-contract schema

**ID:** F-14 · **Roadmap piece:** F-14 · **Status:** Done (merged to main · 2026-05-28)

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
- **Top-level fields** (frozen nested shape, `shared/json_export.schema.json`):
  `schema_version`, `job`, `measurement`, `provenance`, `artifacts`.
  This is the approved divergence from ADR-015's idealized flat sketch —
  the schema was frozen against the real `Measurement` shape. `job_id`
  and `address` live under `job` (`job{id, address, status}`);
  `generated_at` and `warnings` live under `measurement`
  (`measurement{generated_at, warnings, facets, features, …}`).
  `provenance` carries data sources + acquisition dates + model
  versions (nested, best-effort); `artifacts` carries `pdf_url`,
  `model_3d_url`, `share_url`.
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

### Build (2026-05-28)

**The frozen schema is the source of truth, and it differs from this spec's
build-step prose.** The wave-3 barrier already landed
`shared/json_export.schema.json` (and `spec/contracts/json_export_schema_spec.rb`)
on `build/wave-3-surfaces`. The build steps above (written before the barrier
froze) describe a richer/older shape (top-level `job_id`/`generated_at`/
`address`/`warnings`; facet `id` rename + `pitch_ratio` as a `"6/12"` string;
provenance flattened to ADR-015's flat field set). **I built to the frozen
schema, not that prose**, because the barrier contract takes precedence:

- Top level: `schema_version`, `job{id,address,status}`, `measurement|null`,
  `provenance|null`, `artifacts{pdf_url,share_url,model_3d_url}`.
- `measurement.facets[]` keep `facet_id` (NOT renamed to `id`); `pitch_ratio`
  stays a **number** (rise-per-12), not a `"6/12"` string.
- `measurement.predominant_pitch_ratio` is a number; `predominant_pitch_degrees`
  is **derived** (`atan(ratio/12)`).
- `provenance` is passed through best-effort as the orchestrator's **nested**
  shape (the schema is `additionalProperties:true`), NOT flattened.
- `measurement.geocode` emits `{lat,lng,confidence}` — `lon` renamed to `lng`.

**Libraries/patterns**

- `json_schemer` 2.5.0 reused — no new gem.
- `app/services/json_export_schema.rb` mirrors `PipelineSchema` (mutex-memoized
  document + root validator; `version` read from the schema's `schema_version`
  `const` so nothing hard-codes `"1.0.0"`). One gotcha vs PipelineSchema: the
  root `validator` must read `document` **outside** the mutex (the mutex is
  non-reentrant; calling `document` inside the lock deadlocks on a cold cache).
  Boot-checked by `config/initializers/json_export_schema.rb`
  (`SKIP_JSON_EXPORT_SCHEMA_BOOT_CHECK=1` escape hatch, warn-in-test).
- `app/serializers/job_export_serializer.rb` is the first class in a new
  `app/serializers/` dir — a plain PORO (no ActiveModel::Serializer; not in the
  Gemfile). Stateless transform; accepts `share_url:`/`pdf_url:` as injected
  args (no url_helpers / hard-coded host). Does NOT validate — the controller
  validates the result and `500`s loudly on serializer drift (a dev bug).

**The three field-mapping footguns** (documented in
`shared/JSON_EXPORT_CONVENTIONS.md` with explicit tests):
1. Facet `vertices` FLIP `[lon,lat]` → `[lat,lng]` (silent-bug risk: both are
   number pairs; a missing flip still validates).
2. `predominant_pitch_degrees` derived from the stored ratio.
3. Feature `position_lat_lng` **omitted** — `bbox_norm` is normalized image
   space, not georeferenceable by the serializer (v1.0.0 limitation).

**Auth / CORS**

- `Api::V1::JsonExportsController#show` skips `require_demo_login` and adds a
  JSON `before_action` that returns `401` (not the inherited `302`) when not
  logged in — so non-redirect-following tools fail cleanly. No CORS header.
- `ReportsController#export_public` (added to the `skip_before_action` list)
  uses the frozen resolver (`Report.find_by!(share_token:)`; bad token →
  `head :not_found`), sets `Access-Control-Allow-Origin: *` and reuses
  `X-Robots-Tag: noindex`. CORS is controller-set (no rack-cors gem).
- Both routes return the **identical** serializer output (public-share-identity
  rule). Propagated to ROADMAP Cross-Cutting.

**Routing**: the public JSON route is an explicit `r/:token.json` path
(`format: false`) declared *before* the HTML `r/:token` route. A format
*default/constraint* alone is insufficient — an extension-less HTML request also
satisfies a `format: :json` default and would steal the route; baking `.json`
into the path keeps `/r/:token` (HTML) and `/r/:token.json` (JSON) distinct.

**Resolver contract divergence from this spec's prose:** the prose build steps
say the public/auth JSON routes `404` when there's no measurement. The frozen
barrier says nil job OR nil measurement ⇒ **`200`-with-null-artifacts JSON,
never `500`**, and the schema permits a null measurement. I followed the barrier:
both routes return `200` with a `null` measurement for a not-ready job (only an
unknown token / unknown job id / bad auth produce `404`/`401`). See contractDrift
note: an *orphaned* Report with a `nil` job cannot produce a schema-valid `200`
(the schema requires string `job.id`/`job.status`), but that case is not
producible by the orchestrator (it always creates `Report.find_or_create_by!(job:)`).

**Report-creation barrier**: already resolved in the barrier commit — the
orchestrator mints the Report idempotently on `:ready`. F-14 does not own that
change and degrades gracefully. ROADMAP rows added ("Report row creation",
"JSON export public-share identity").

**What F-12/F-13 must inherit**: the `[lat,lng]` coordinate convention, the
`artifacts.{pdf_url,share_url,model_3d_url}` field names, and the identical
public-vs-private output rule. `pdf_url` is `null` until `report.pdf` exists in
Spaces (this export links/probes, never triggers generation — F-13 owns the PDF
routes + the minted URL).

---

## Build plan (approved) — planned 2026-05-28

> Generated by the plan-iteration pass and reconciled into the shared
> contract manifest in [`../BUILD-PLAN.md`](../BUILD-PLAN.md). The frozen
> contracts + shared barrier in that manifest take precedence over any
> step below if they disagree. **Approve before building.**

> **Human resolutions (2026-05-28) — apply these:**
> - **Omit feature `position_lat_lng`** (image-space `bbox_norm` is not georeferenceable — do not fake it).
> - **Provenance fields are optional/best-effort** (orchestrator emits a nested, partial shape; omit what isn't produced).
> - **Lock ADR-015's field names** (`area_sq_ft`, `pitch_ratio` `"6/12"`, `pitch_degrees`, `[lat,lng]`) now — no chasing a proprietary Xactimate/EagleView sample.
> - **The schema is a PROTOTYPE.** No external consumer is locked in yet, so v1.0.0 need not be perfect and can change freely. The breaking-change CI guard is a drift-catcher, not a hard external contract — keep it, but don't agonize over permanence. Don't over-engineer versioning ceremony.

**Recommended build model tier:** `opus` — Designs a NEW versioned public contract against real (not ADR-idealized) data, the nested->flat provenance map, the [lon,lat]->[lat,lng] flip (silent-bug risk), and the 401/CORS semantics — contract-defining, error-prone if rushed.

### Summary

F-14 ships the JSON export as a versioned public contract (ADR-015): a new shared/json_export.schema.json (JSON Schema draft 2020-12, schema_version "1.0.0"), a stateless JobExportSerializer that transforms a Job + its latest_measurement into the documented public shape, a JsonExportSchema loader/validator mirroring the existing app/services/pipeline_schema.rb pattern (memoized, mutex, fail-fast-at-boot initializer), and two routes: GET /api/v1/jobs/:id.json (auth-required, returns 401 NOT 302 for tools) and GET /r/:token.json (public, token-gated, permissive CORS via controller-set headers since there is no rack-cors gem). The architect's clean serializer/validator split is the backbone; the researcher's facts anchor it (json_schemer 2.5.0 already in Gemfile; CI already runs `bundle exec rspec` so the schema-validation spec gates automatically with no new CI job). The contrarian's coupling warnings are taken seriously and resolved by reading the real code: (a) the Report-creation gap is a genuine cross-feature barrier shared by F-12/F-13/F-14 — F-14 does NOT own the orchestrator change; it freezes the resolution as a shared-contract need and degrades gracefully (null artifact URLs) when no Report exists; (b) the actual Measurement field shapes diverge materially from ADR-015's idealized example and ALL THREE drafts glossed this — verified facts: facets store facet_id/vertices([lon,lat] WGS84)/pitch_ratio(number rise-per-12), features store bbox_norm in [0,1] IMAGE space (so position_lat_lng is NOT derivable and must be omitted/nulled, not faked), provenance is nested (attributions/retrieved_at) not the flat imagery_source/sam2_version/vlm_model of the ADR example. The serializer's mapping rules and these gaps are documented in shared/JSON_EXPORT_CONVENTIONS.md and the feature implementation notes, and the schema is designed against REAL data not the aspirational ADR example.

### Dependencies (verified present in code)

- app/services/measurement_orchestrator.rb#persist/#build_measurement_document/#build_provenance — verified to populate Measurement.facets/features/provenance/geocode/total_area_sq_ft/total_perimeter_ft/predominant_pitch_ratio/warnings/source/confidence (F-10, landed).
- Job#latest_measurement (verified, returns newest by generated_at) and Job#address column.
- Report model with has_secure_token :share_token + to_param => share_token + belongs_to :job optional (verified, F-03).
- app/services/pipeline_schema.rb + config/initializers/pipeline_schema.rb — the proven memoized/mutex/fail-fast loader pattern JsonExportSchema copies (verified present).
- json_schemer 2.5.0 in Gemfile.lock (verified).
- shared/pipeline_schema.json $defs (Facet, Feature, GeometrySource, Confidence, Address) — the internal contract the export maps FROM (verified shapes).
- ApplicationController#require_demo_login + #logged_in? + the dev-login session mechanism, and the api/v1/capture_sessions_controller 401 pattern (verified).
- config/routes.rb existing api/v1 namespace and the 'r/:token' => reports#show_public HTML route (verified).
- .gitlab-ci.yml rails_test job runs `bundle exec rspec` against a PostGIS+PostgreSQL service (verified — no new CI job needed).

### Shared-contract touch points

> These are reconciled and frozen in `BUILD-PLAN.md`. Build to the frozen
> signatures there, not to prose in this spec.

- shared/json_export.schema.json — the NEW public contract (JSON Schema draft 2020-12, schema_version locked '1.0.0'), DISTINCT from shared/pipeline_schema.json (internal contract, currently 0.3.0). Versioned independently per ADR-015. F-12/F-13 must reuse its field names ([lat,lng] order, area_sq_ft, pitch_ratio 'N/12', pitch_degrees) and its artifacts.{pdf_url,share_url} fields if they surface the same data.
- Report-row creation rule — BARRIER ITEM, shared by F-12/F-13/F-14. The F-10 orchestrator persists a Measurement and flips Job to :ready but NEVER creates a Report (verified). The public /r/:token.json (and F-12 viewer, F-13 PDF public share) all need a Report to resolve token->job->latest_measurement. Decide BEFORE parallel build WHO mints the Report (orchestrator on :ready is cleanest; or a callback). F-14 must NOT own the orchestrator change; it degrades gracefully (artifacts.share_url/pdf_url null) when no Report exists.
- Public-share-identity rule — /api/v1/jobs/:id.json and /r/:token.json return IDENTICAL JobExportSerializer output; the only differences are auth (401) vs token-gate (404) and CORS. No redaction, no route-conditional serializer branches. Frozen in ROADMAP Cross-Cutting so F-12/F-13 do not diverge their public-vs-private data.
- Auth-failure semantics for api/v1 JSON — GET /api/v1/jobs/:id.json must return 401 (not the ApplicationController default 302 redirect to login) so downstream tools that don't follow redirects fail cleanly. Established pattern: skip require_demo_login + a JSON 401 before_action (mirrors api/v1/capture_sessions). Any future api/v1 JSON endpoint should follow this.
- CORS = controller-set response headers, NOT a gem — Gemfile has no rack-cors (verified). /r/:token.json sets Access-Control-Allow-Origin: * in the controller; /api/v1 sets none. If a future feature needs middleware-level CORS this row must be revisited.
- Measurement field-shape dependency — the serializer reads facets (facet_id/vertices[lon,lat]/pitch_ratio number/area_sq_ft/source/confidence), features (label/bbox_norm[0,1] image-space/verified/source/confidence — NO geographic position), provenance (NESTED {attributions,retrieved_at,lidar_work_unit,detector,sam2_backend,generated_at}, not ADR-015's flat fields), geocode (Address {lon,lat,...}), and Job#address. If F-10/orchestrator evolves these jsonb shapes, the serializer + sample.json must update together (the integration boundary between F-10 and F-14).
- json_schemer ~> 2.3 (resolved 2.5.0) already in Gemfile — reused for JsonExportSchema; no new gem. CI rails_test already runs `bundle exec rspec`, so the schema-validation contract spec gates automatically — no new .gitlab-ci.yml job.

### Build steps

- [x] **Verify and freeze the field-mapping contract against real Measurement data before writing the schema**
  - Re-read app/services/measurement_orchestrator.rb#persist (lines ~485-510), #build_measurement_document (~448-465), #build_provenance (~551-580). Confirm verified shapes: Measurement.facets items = {facet_id, vertices ([lon,lat] WGS84), pitch_ratio (NUMBER, rise-per-12 e.g. 6.0), pitch_degrees, area_sq_ft, source (GeometrySource enum), confidence}; Measurement.features items = {label, bbox_norm ([x0,y0,x1,y1] in [0,1] IMAGE space), verified, source, confidence} — NO geographic position; Measurement.provenance = {pipeline_schema_version, detector, sam2_backend, geometry_source, lidar_work_unit:{name,year,...}, attributions:{...}, retrieved_at:{...}, generated_at} (NESTED, not the flat ADR-015 example); Measurement.geocode = Address {raw, normalized, lon, lat, confidence}; Job#address is the raw column. Record the exact source->export mapping decisions (including that feature.position_lat_lng is NOT derivable from bbox_norm and will be OMITTED in v1.0.0, not faked) as the basis for the schema and conventions doc.
- [x] **Create shared/json_export.schema.json (JSON Schema draft 2020-12) matching REAL data, not the ADR example**
  - Root object with $schema draft 2020-12, $id, title, schema_version enum ["1.0.0"]. Top-level required per spec: schema_version, job_id, generated_at, address, measurement, provenance, artifacts, warnings. $defs for Address {raw, geocoded:{lat,lng}|null}, Facet {id, vertices_lat_lng [[lat,lng]...], area_sq_ft, pitch_ratio (string pattern ^[0-9]+(\.[0-9]+)?/12$), pitch_degrees, source, confidence}, Feature {id, label (enum vent|chimney|dormer|skylight|satellite_dish|other), confidence, source, verified} — NO position_lat_lng in v1.0.0 since it is not derivable; Provenance {imagery_source, imagery_acquired_at, lidar_source, lidar_work_unit, lidar_acquired_at, sam2_version, vlm_model, pipeline_version} all OPTIONAL (orchestrator does not populate all today); Artifacts {pdf_url|null, model_3d_url|null, share_url|null}; Confidence number [0,1]; source enum matching GeometrySource (lidar|imagery|fusion|capture|manual) plus the feature 'vlm:<model>' free-string allowance. measurement = {total_area_sq_ft, total_perimeter_ft, primary_pitch_ratio (string|null), primary_pitch_degrees|null, facets[], features[]}. No F-NN refs anywhere in the file. Validate the file parses and is itself a valid draft-2020-12 schema.
- [x] **Create app/services/json_export_schema.rb mirroring PipelineSchema**
  - Copy the proven pattern from app/services/pipeline_schema.rb: module JsonExportSchema, SCHEMA_PATH = Rails.root.join('shared','json_export.schema.json'), META_SCHEMA draft 2020-12, Mutex-memoized document + per-entity validators, load!/document/version/validator_for/valid?/errors_for, LoadError on missing/malformed. version reads the schema's const default for schema_version (the locked '1.0.0'). Live in app/services (NOT lib/) to match the existing convention.
- [x] **Create config/initializers/json_export_schema.rb fail-fast boot check**
  - Copy config/initializers/pipeline_schema.rb verbatim in structure: after_initialize { JsonExportSchema.load! } with the same Rails.env.test? + SKIP_*_BOOT_CHECK escape hatch and the test-env warn-instead-of-raise fallback, so a missing/malformed export schema fails at boot in prod, not as a first-request 500.
- [x] **Write spec/contracts/json_export_schema_spec.rb FIRST (test-first, repo convention)**
  - Mirror spec/contracts/pipeline_schema_spec.rb. Assert: (a) schema loads and JsonExportSchema.version == '1.0.0'; (b) the committed spec/fixtures/json_export/sample.json validates green; (c) a deliberately-broken payload (missing required schema_version; pitch_ratio as a number not 'N/12' string) validates RED with a useful error pointer; (d) breaking-change guard: the schema's top-level required[] still contains schema_version, job_id, generated_at, address, measurement, provenance, artifacts, warnings (removing any fails the build). This spec runs under the existing rails_test `bundle exec rspec` — no new CI job needed.
- [x] **Create spec/fixtures/json_export/sample.json (hand-crafted, complete, schema-green)**
  - A realistic export with all top-level fields, >=1 facet (id 'facet-1', vertices_lat_lng a closed ring of [lat,lng], area_sq_ft, pitch_ratio '6/12', pitch_degrees 26.57, source 'fusion', confidence 0.92) and >=1 feature (id 'feat-1', label 'chimney', source 'vlm:gemini-flash-2.0', confidence 0.88, verified true — NO position_lat_lng), provenance with the fields the serializer can actually produce, artifacts with share_url set + pdf_url/model_3d_url null, warnings with one string. Path is spec/fixtures/json_export/sample.json (the spec's named location; ADR-015's spec/fixtures/sample_export.json is superseded by the feature spec).
- [x] **Write spec/services/job_export_serializer_spec.rb FIRST**
  - Build a Job + Measurement via the existing :job/:measurement factories (populate facets/features/provenance/geocode/total_area_sq_ft/total_perimeter_ft with realistic values; create a :report for the artifacts path). Assert: to_h returns a Hash whose top-level keys match the schema; facet transform renames facet_id->id, vertices([lon,lat])->vertices_lat_lng([lat,lng]) with coordinate FLIP, pitch_ratio number 6.0 -> string '6/12'; feature transform passes label/source/confidence/verified and OMITS position; provenance maps nested orchestrator shape to the flat export shape (documenting which fields are absent); address.raw from job.address, address.geocoded from measurement.geocode {lat,lng} (or null when geocode lon/lat absent); source+confidence are NEVER dropped (honest-uncertainty rule); the produced hash validates green via JsonExportSchema.valid?; nil latest_measurement raises a clear error (caller's 404 responsibility).
- [x] **Create app/serializers/job_export_serializer.rb (stateless pure transform)**
  - This is the first class in a new app/serializers/ dir (no precedent — sets the pattern). JobExportSerializer.new(job, share_url: nil, pdf_url: nil, model_3d_url: nil). Reads job.latest_measurement. #to_h builds the schema shape: schema_version = JsonExportSchema::VERSION constant (NOT a literal, to avoid drift), job_id, generated_at = measurement.generated_at.iso8601, address {raw: job.address, geocoded: geocode.lat/lng or null}, measurement {total_area_sq_ft, total_perimeter_ft, primary_pitch_ratio (format predominant_pitch_ratio as 'N/12'), primary_pitch_degrees (derive from ratio via atan), facets: mapped, features: mapped}, provenance: mapped from measurement.provenance (best-effort: pull lidar_work_unit/attributions/detector; absent fields omitted), artifacts: {pdf_url, model_3d_url, share_url} from injected args (null when no Report), warnings: measurement.warnings. Facet/feature mapping per the frozen contract. Do NOT validate inside the serializer (controller's job). Do NOT use url_helpers with a hard-coded host — accept URLs as injected args from the request-aware controller.
- [x] **Add routes for both endpoints in config/routes.rb**
  - Under namespace :api { namespace :v1 } add: get 'jobs/:id' => 'jobs#export', defaults:{format: :json}. Outside any namespace, parallel to the existing 'r/:token' HTML route: get 'r/:token' => 'reports#export_public', defaults:{format: :json}, constraints:{format: 'json'} (or a distinct path 'r/:token.json') so it does not collide with the existing reports#show_public HTML route. No F-NN comments — reference ADR-015 by name in any inline comment.
- [x] **Write spec/requests/api/v1/json_export_spec.rb FIRST (auth endpoint, 401 semantics)**
  - (1) GET /api/v1/jobs/:id.json WITHOUT login returns 401 (NOT 302 redirect, NOT a Location header) — API-tool semantics per spec; (2) WITH login (session[:demo_logged_in]=true via the dev-login helper) for a ready job returns 200, Content-Type application/json, top-level object (not wrapped) with schema_version '1.0.0' and all required keys, and field naming area_sq_ft / pitch_ratio '6/12' string / pitch_degrees number; (3) WITH login but job.latest_measurement nil returns 404; (4) the response has NO Access-Control-Allow-Origin header (auth route is locked down).
- [x] **Create app/controllers/api/v1/json_exports_controller.rb (or jobs_controller.rb#export) returning 401 not 302**
  - Inherit ApplicationController but OVERRIDE the auth failure to be 401 for JSON: skip_before_action :require_demo_login and add a before_action that does `return if logged_in?; render json: {error: 'authentication required'}, status: :unauthorized` (mirrors the api/v1/capture_sessions 401 style; the inherited require_demo_login would 302 which tools don't follow). Find Job by id; head/render 404 if not found or latest_measurement nil; serialize via JobExportSerializer.new(job, share_url: resolved-from-report-if-any); validate via JsonExportSchema — on failure render 500 with the error detail (loud, developer-facing; serializer drift is a bug); render json: hash, status: :ok. Set NO CORS header here.
- [x] **Write spec/requests/public_json_export_spec.rb FIRST (public endpoint, CORS, noindex)**
  - (1) GET /r/:token.json for unknown token returns 404 with no body leak; (2) for a valid token (create :report with job) returns 200 + application/json; (3) response has Access-Control-Allow-Origin: * ; (4) response has X-Robots-Tag: noindex; (5) round-trip: parse JSON, assert schema_version, job_id == report.job_id, and core measurement fields match the source Measurement; (6) when the report's job has no measurement, returns 404.
- [x] **Add ReportsController#export_public (mirror show_public, JSON + CORS)**
  - In app/controllers/reports_controller.rb add export_public to the skip_before_action :require_demo_login list. Find Report.find_by!(share_token: params[:token]); rescue RecordNotFound -> head :not_found. Resolve report.job.latest_measurement; 404 if nil. Serialize via JobExportSerializer.new(job, share_url: public_report_url(token: report.share_token)). Validate via JsonExportSchema (500 on drift). Set response headers: 'Access-Control-Allow-Origin' => '*' and reuse the existing 'X-Robots-Tag' => 'noindex'. render json: hash. CORS is set in the CONTROLLER (no rack-cors gem in Gemfile — confirmed).
- [x] **Create shared/JSON_EXPORT_CONVENTIONS.md**
  - Document field-naming rationale and the REAL mapping: area_sq_ft (industry/Xactimate-EagleView convention, sq ft not m2 at presentation boundary per CRS-discipline rule); pitch_ratio as 'N/12' string + pitch_degrees decimal; coordinates as [lat,lng] (note: export FLIPS the internally-stored WGS84 [lon,lat] to [lat,lng] to match insurance-tool convention — state this loudly since it is a footgun); confidence [0,1]; source GeometrySource enum + 'vlm:<model>' for features. CRITICAL documented gaps: (a) feature.position_lat_lng is OMITTED in v1.0.0 because bbox_norm is normalized IMAGE space with no georeference available to the serializer; (b) provenance export fields are best-effort — the orchestrator currently produces a nested {attributions, retrieved_at, lidar_work_unit, detector, sam2_backend} shape, NOT all of ADR-015's flat fields, so missing keys are omitted. Cite the manual-setup Xactimate/EagleView reference (see manualSetup). Versioning philosophy: v1.x additive-only, v2.x breaking.
- [x] **Create shared/JSON_EXPORT_CHANGELOG.md**
  - v1.0.0 (2026-05-28): initial release. List every top-level + nested field shipped. Note semver rules (major=breaking, minor=additive, patch=docs/examples) and that any PR editing shared/json_export.schema.json must add a changelog entry and keep all v1.0.0 required fields required. Template stub for future versions.
- [x] **Create docs/JSON_EXPORT_API.md**
  - Brief endpoint reference: GET /api/v1/jobs/:id.json (auth required; 401 — not 302 — for unauthenticated, since downstream tools do not follow redirects; 404 if no measurement; 200 + JSON). GET /r/:token.json (public, token-gated; 404 on bad token; permissive CORS; noindex). One example payload (link to / reuse the sample.json). curl snippets for both. Link to shared/json_export.schema.json as the authoritative contract. No F-NN references.
- [x] **Add the Report-creation + public-share-identity cross-cutting rows to docs/ROADMAP.md**
  - Append to the Cross-Cutting Concerns table (after verifying no such row exists — confirmed it does not): (1) 'Report row creation' — define WHEN a Report is minted (resolution owned at the shared-contract barrier, not inside F-14; until then F-14 nulls artifacts.share_url/pdf_url and the public /r/:token.json relies on a Report being created by F-12/F-13 or the orchestrator); (2) 'JSON export public-share identity' — /api/v1/jobs/:id.json and /r/:token.json return the IDENTICAL JobExportSerializer output; difference is auth (401) vs token-gate (404) + CORS only; no redaction or route-conditional serializer logic. Reference ADR-015/ADR-016 by name, no F-NN refs in the table cells.
- [x] **Record implementation notes in docs/features/14-json-export-endpoint.md**
  - Fill the empty Implementation notes section: json_schemer 2.5.0 reused (no new gem); JsonExportSchema mirrors PipelineSchema (app/services + boot initializer); serializer is a stateless transform validated in the controller (not the model/serializer) so dev can render invalid JSON loudly as 500; the THREE field-mapping facts that diverge from ADR-015's example (facet vertices [lon,lat]->[lat,lng] flip + facet_id->id + pitch_ratio number->'N/12'; feature position_lat_lng OMITTED because bbox_norm is image-space; provenance nested-real-shape vs flat-ADR-example, best-effort); the Report-creation cross-feature decision and graceful-null degradation; what F-12/F-13 must inherit (the [lat,lng] convention + the artifacts URL fields + the identical-output rule). Cross-cutting discoveries already propagated to ROADMAP.
- [x] **Run the full suite and confirm green + no F-NN leakage**
  - Run `bundle exec rspec spec/contracts/json_export_schema_spec.rb spec/services/job_export_serializer_spec.rb spec/requests/api/v1/json_export_spec.rb spec/requests/public_json_export_spec.rb` against the PostGIS DB (config/database.yml localhost:5433, run bare with no env vars per repo convention). Confirm all green, then grep all committed code/config/shared/docs (excluding docs/features/14-*.md and commit messages) for 'F-14'/'F-NN' and remove any. Confirm the schema-validation spec is picked up by the existing rails_test `bundle exec rspec` (no .gitlab-ci.yml change needed).

### Test strategy

Test-first per repo convention, four suites matching the existing layout. (1) spec/contracts/json_export_schema_spec.rb (mirrors pipeline_schema_spec.rb): schema loads + version '1.0.0'; spec/fixtures/json_export/sample.json validates green; deliberately-broken payloads validate red; breaking-change guard asserts the v1.0.0 required[] set is intact. (2) spec/services/job_export_serializer_spec.rb: factory Job+Measurement(+Report); assert top-level keys, facet field renames + [lon,lat]->[lat,lng] flip + pitch_ratio number->'6/12' string, feature transform omitting position, provenance nested->flat best-effort mapping, address.geocoded from geocode, source+confidence never dropped, output validates green, nil measurement raises clearly. (3) spec/requests/api/v1/json_export_spec.rb: 401 (not 302, no Location) unauthenticated; 200 + correct shape + field naming authenticated; 404 when no measurement; NO CORS header. (4) spec/requests/public_json_export_spec.rb: 404 unknown token; 200 valid token; Access-Control-Allow-Origin: * present; X-Robots-Tag: noindex present; round-trip parse matches source; 404 when report's job has no measurement. All run via `bundle exec rspec` against the PostGIS DB (localhost:5433, bare/no-env per convention) inside the existing rails_test CI job — the contract spec is the breaking-change gate, no new CI job. Final: grep for F-NN leakage in committed artifacts (excluding the feature file + commits).

### Risks

- position_lat_lng is NOT derivable: Measurement.features carry bbox_norm in [0,1] IMAGE space against a satellite tile, with no tile georeference available to the Rails serializer. ADR-015's example shows feature position_lat_lng — but producing it would require faking a transform. Resolution: OMIT position_lat_lng from the Feature shape in v1.0.0 (additive in a later minor if the orchestrator starts emitting a geographic centroid). This is a documented deliberate deviation from the ADR example. If a reviewer expects position_lat_lng present, escalate before locking v1.0.0.
- Provenance shape mismatch: the orchestrator's real provenance is nested ({attributions, retrieved_at, lidar_work_unit, detector, sam2_backend, pipeline_schema_version, generated_at}) NOT the flat {imagery_source, imagery_acquired_at, sam2_version, vlm_model, pipeline_version} of ADR-015's example. The serializer must best-effort map nested->flat and OMIT fields the orchestrator doesn't produce (e.g. vlm_model/sam2_version may be absent). Schema marks all provenance fields optional. Risk: an incomplete provenance block could disappoint the 'how do I know?' adjuster narrative; documented as a known v1.0.0 limitation.
- Coordinate-order footgun: internal storage is WGS84 [lon,lat] (Facet.vertices) but the export uses [lat,lng] per insurance-tool convention. The serializer FLIPS them. A silent failure to flip would ship subtly-wrong coordinates that still validate (both are numbers). Mitigation: explicit serializer test asserting the flip, and a loud note in JSON_EXPORT_CONVENTIONS.md.
- Report-creation gap blocks end-to-end public export: with no Report created today, /r/:token.json 404s for every real job until F-12/F-13/orchestrator mint a Report. F-14's tests use a factory-created :report so they pass, but the feature is not end-to-end until the barrier decision lands. Mitigation: surfaced as the top shared-contract need + ROADMAP row.
- Auth 401 vs 302: the inherited require_demo_login redirects (302). Forgetting to override it for the api/v1 JSON endpoint would break the documented 401 contract for tools. Mitigation: explicit request spec asserting 401 and no Location header.
- Schema-version drift: hard-coding '1.0.0' as a literal in the serializer would let a bumped schema silently mismatch. Mitigation: serializer references JsonExportSchema::VERSION constant, and the contract spec asserts version == '1.0.0' against the schema file.
- CORS on a bearer-token-in-URL surface: Access-Control-Allow-Origin: * on /r/:token.json is intentional (browser tools) but the share token is a URL-borne bearer credential. Provenance/attributions are public-safe; confirm no internal-only fields (e.g. raw source IPs, internal model build hashes) leak into the export. Brief the security reviewer with the outbound-data lens.
- New app/serializers/ pattern: no serializer precedent exists. Introducing JobExportSerializer sets a convention F-12/F-13 may inherit; keep it a plain PORO (not ActiveModel::Serializer, which is not in the Gemfile) to avoid a dependency surprise.

### Manual setup (human-gated)

- Locate a real Xactimate or EagleView JSON output sample (industry forum post, vendor API docs, or LLM-fabricated + human-verified) to anchor field-naming choices, and cite the source in shared/JSON_EXPORT_CONVENTIONS.md. These formats are not freely public; if no authoritative sample is found, the tech lead must sign off that ADR-015's names (area_sq_ft, pitch_ratio 'N/12', pitch_degrees, [lat,lng]) are the locked v1.0.0 convention before merge (a v2.0 break is the only fix later).
- Tech-lead sign-off on the two deliberate deviations from ADR-015's example payload before locking v1.0.0: (a) Feature has NO position_lat_lng (bbox_norm is image-space, not derivable); (b) provenance fields are best-effort/optional rather than the full flat set, because the F-10 orchestrator produces a nested, partial provenance shape today.

### Open questions for the human

- Who mints the Report row, and when? (Orchestrator on Job->:ready, a callback, or lazily on first viewer/PDF access?) This is the cross-feature barrier shared with F-12/F-13 and must be resolved before parallel build, or the public JSON endpoint 404s for real jobs (F-14 tests pass via factory Report regardless).
- Confirm the deliberate v1.0.0 deviations from ADR-015's example are acceptable: Feature.position_lat_lng OMITTED (not derivable from image-space bbox_norm), and provenance fields OPTIONAL/best-effort (orchestrator emits nested {attributions,retrieved_at,lidar_work_unit,detector,sam2_backend}, not the flat {imagery_source,sam2_version,vlm_model,...}). Or should F-10 be asked to enrich provenance + emit a feature geographic centroid first?
- Authoritative industry field-naming reference: is a real Xactimate/EagleView JSON sample obtainable, or do we lock ADR-015's names by tech-lead fiat? (Locking v1.0.0 on unverified names risks a v2.0 break.)
- Artifact URLs: where do pdf_url / model_3d_url ultimately point (ActiveStorage blob URL vs Spaces CDN under artifacts/public/<token>/)? For v1.0.0, F-14 ships them null until F-13 (PDF) / 3D model exist and a Report carries them. Confirm null-now is acceptable.
- Should address.geocoded be null vs an omitted key when measurement.geocode has null lon/lat (un-geocoded address)? Plan assumes null-valued object; confirm consumers prefer that over key omission.
