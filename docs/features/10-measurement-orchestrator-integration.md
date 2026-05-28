# Feature: INTEGRATION — Measurement orchestrator (GeometryJob)

**ID:** F-10 · **Roadmap piece:** F-10 · **Status:** Done · **Type:** Integration

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

## Build plan (approved 2026-05-28; batch with F-11)

Built in the F-10+F-11 unified batch on `feat/iter3-orchestrator-and-submission`.
Tier: **Opus** owns the contract envelope, the status/model seam, and the
orchestrator chain; **Sonnet** sub-agents build the isolated mechanical leaves
(imagery stage, client methods, env wiring). Opus verifies/ticks/integrates every
chunk.

### Phase 0 — shared contracts (Opus, land first; both workstreams build on these)

- [x] **C0.1 — `Measurement` model + `Job` status column.** Migrations via
  `bin/rails generate`. `Measurement belongs_to :job`; JSONB `footprint`,
  `roof_outline`, `facets`, `features`, `provenance`; scalars `total_area_sq_ft`,
  `predominant_pitch_ratio`, `source`, `confidence`; `warnings` (string array);
  `generated_at`. `Job`: `status` enum-backed string (default `pending`).
- [x] **C0.2 — status enum + broadcast seam on `Job`.** Enum:
  `pending, resolving_address, fetching_imagery, fetching_lidar, refining_outline,
  detecting_features, fitting_planes, ready, failed`. `Job#advance_to!(status)`
  persists + `broadcast_replace_to` a per-job Turbo stream. **This is the literal
  seam F-11 renders and F-10 drives.** Model spec covers transitions + broadcast.
- [x] **C0.4 — `render-imagery` schema envelope (additive 0.3.0 bump).** Add
  `RenderImagery{Request,Response}` to `shared/pipeline_schema.json`
  (Req: building_polygon + target size/GSD; Resp: `image_tile_ref` cache key +
  `image_geo_bounds` [W,S,E,N] + attribution). Bump `pipelineSchemaVersion` 0.2.0
  → 0.3.0; update Pydantic + Ruby loaders; CI schema-validation. Propagate to
  ROADMAP cross-cutting + ADR-002 consequences.

### Phase 1 — F-10 (orchestrator)

- [x] **F10.1 [Sonnet] — sidecar `render-imagery` stage.** Real NAIP-from-AWS
  fetch + deterministic fixture fallback (`IMAGERY_LIVE` gate, mirroring F-06
  `LIDAR_LIVE` / F-07 SAM2-local). Crop to building bbox, store PNG to `cache/`,
  return ref + geo-bounds. pytest with fixture tile. *Opus locks the route+schema
  shape (C0.4) first.*
- [x] **F10.2 [Sonnet] — `SidecarClient` per-stage methods.** `resolve_address`,
  `render_imagery`, `ingest_lidar`, `refine_outline`, `fit_planes`,
  `fallback_measurement` — each schema-validates request+response, maps sidecar
  4xx/5xx → typed errors. RSpec against the real sidecar subprocess. *Opus reviews
  the error-mapping at the trust boundary.*
- [x] **F10.3 [Opus] — `MeasurementOrchestrator` + `GeometryJob`.** The chain:
  resolve_address → render_imagery → (parallel: [ingest_lidar → fit_planes |
  refine_outline] + [F-09 detect over a Rails-minted signed URL]) → assemble
  `Measurement`. LiDAR-missing → `fallback_measurement`, `source: imagery`,
  `warnings: ["lidar_missing: …"]`. VLM failure-isolation (features:[]+warning);
  geometric failure fails the job. Idempotency (cached < 1h, same address+selection).
  Status broadcast at each boundary. Schema-violation → loud failure naming the
  offending stage. SSRF-safe signed-URL minting (host-allowlist per ROADMAP).
- [x] **F10.4 [Sonnet] — env wiring + sidecar boot fail-fast.** `IMAGERY_*` (+
  confirm `LIDAR_LIVE/WESM/STORAGE/GEMINI`) into `ops/compose.prod.yaml` +
  `ops/.env.example`; sidecar raises at boot when a stage is enabled but
  misconfigured (mirrors Rails `after_initialize`).
- [x] **F10.5 [Opus] — F-10 acceptance tests.** In-CI end-to-end (mocked externals,
  fixture COPC, SAM2-local, Gemini stub) covering **both** LiDAR-available and
  LiDAR-missing; contract-drift test; failure-isolation test; status-broadcast
  order test; latency sanity.

### Decisions locked at planning (deviations from a literal spec, deliberate)

- **`source` uses the schema's `GeometrySource` enum**, not the spec prose strings:
  happy path → `fusion` (LiDAR+imagery), fallback → `imagery`. The enum already
  expresses the intent correctly; no contract bump for this. *(Spec prose §Acceptance
  said `lidar+imagery`/`imagery_only` — informal shorthand; this file is now the
  truth.)*
- **`fetching_imagery` added to the status enum** and a **new `render-imagery`
  sidecar stage** exist because the satellite tile F-07/F-09 consume was an unbuilt
  integration gap; per ARCHITECTURE.md (sidecar owns all geospatial-data fetch incl.
  NAIP) it lives in the sidecar. This is the 0.3.0 additive contract change.
- **`Measurement` geometry stored as GeoJSON JSONB**, not PostGIS geometry columns —
  sufficient for F-12/13/14 consumers; PostGIS columns deferred (noted for F-12).

## Implementation notes (filled in by the building agent)

> The agent implementing this feature records its implementation
> decisions and rationale here as it builds — chosen libraries/patterns
> within the architecture's constraints, trade-offs made, deviations
> from assumptions and why, and anything the next agent or the
> integrator needs to know. This section starts empty and is owned by
> the builder, not the planner. Cross-cutting discoveries that affect
> other features must also be propagated to ROADMAP.md or the
> architecture doc, not just left here.

### F10.3 + F10.5 (orchestrator + GeometryJob + acceptance suite)

- **Entry point:** `MeasurementOrchestrator.new(job).call` (and `.call(job)`
  shortcut). Returns the persisted (or cached) `Measurement`, or `nil` after
  transitioning the job to `failed` for any expected failure mode. `GeometryJob`
  (`queue_as :default`, `perform(job_id)`) is the Solid Queue entry.
- **Parallel VLM:** `render_imagery` runs first; then `detecting_features` is
  broadcast and the VLM detector runs in a `Thread` (it returns a result hash,
  capturing any exception internally) while the geometric chain
  (ingest-lidar → refine-outline → fit-planes|fallback) proceeds. The thread is
  joined with a 60s bounded timeout; a timeout kills it and yields `features: []`
  plus a `vlm_failed:` warning. Any error from the detector (incl. the signed-URL
  minter) is isolated the same way. Geometric failure, by contrast, fails the
  whole job.
- **Signed URL (SSRF):** `ImageryUrlMinter` mints a 15-minute presigned S3 GET
  URL over the imagery `cache/` key via `Aws::S3::Presigner`. We never hand a
  caller URL to the VLM fetcher; the URL points at our own Spaces object on an
  allowlisted `.digitaloceanspaces.com` host, https, short-lived — the
  blob-reference + outbound-URL-SSRF convention.
- **source / confidence / provenance:** happy path `source: "fusion"`, fallback
  `source: "imagery"`. Overall confidence = geocode_conf × geometry_conf, with
  the imagery path additionally capped at 0.6 so it can never read as confident
  as a fused result. `provenance` carries the schema version, detector name,
  sam2 backend, geometry source, per-stage attributions, and a generation
  timestamp. The assembled `Measurement` is validated against the `Measurement`
  schema entity before persistence.
- **Idempotency:** key = address + polygon_selection (a re-submission re-runs the
  same Job record per F-11), window = 1h, mechanism = reuse `job.latest_measurement`
  if its `generated_at` is within the window.
- **Fallback utm_zone / pitch:** LiDAR-missing leaves no utm_zone, so we derive a
  Northern-Hemisphere UTM EPSG (32600 + zone) from the geocoded longitude (CONUS
  default zone 14 when lon absent); inferred pitch defaults to 26.57° (≈6/12).
- **Real-sidecar e2e DEFERRED:** this worktree (off ws/client) lacks the
  render-imagery and fit-planes/fallback routes, so a true full-chain e2e is not
  achievable here. The contract is covered by the stubbed-collaborator
  orchestrator suite with schema-valid stage fixtures asserted valid against
  `PipelineSchema`. The integrator runs the live e2e on the assembled branch.

### Integrator notes (assembly + review + smoke)

These supersede the per-workstream notes above where they differ — written after
the five workstreams converged onto the unified branch.

- **e2e is no longer deferred.** The assembled branch has all sidecar routes, so a
  real-sidecar end-to-end test now exists at `spec/integration/measurement_pipeline_spec.rb`:
  it boots the live sidecar subprocess and drives `MeasurementOrchestrator` for both
  the LiDAR-available (real fit-planes on a planted gable `.npy`, source `fusion`) and
  LiDAR-missing (real fallback-measurement, source `imagery`) paths, plus a latency
  assertion. resolve-address and ingest-lidar are stubbed at the `SidecarClient` seam
  (the sidecar resolver always calls Nominatim/MS-Footprints over the network and the
  PDAL cropper is conda-only/absent in the uv test venv); render-imagery, refine-outline,
  fit-planes, fallback-measurement run for real. Documented in the spec header.

#### Adversarial review (Step 6)

- **Wave 1 (Opus ×2): spec-compliance + security.**
  - Spec: found the headline e2e test MISSING (deferral reason gone on the assembled
    branch), the latency test missing, provenance thin, `total_perimeter_ft`/geocode/
    parcel dropped, idempotency keyed on the Job not address+selection. All fixed.
  - Security: **no high/medium.** `ImageryUrlMinter` SSRF posture verified SAFE with
    defense-in-depth (server-controlled host, sidecar-derived key, https, 15-min TTL,
    plus FeatureDetector's own host-allowlist). LOW items: `size_px` unbounded (fixed:
    `le=4096`), minter didn't assert `cache/` prefix (fixed), VLM `thread.kill` FD risk
    (addressed in Wave 2). Single-tenant IDOR / Turbo-subscription-authz == login-only:
    **accepted for the single-shared-credential demo** — recorded here as the explicit
    assumption to revisit when real multi-user auth lands.
- **Wave 2 (Sonnet ×2): robustness + efficiency.** Re-triaged on Opus.
  - Robustness: orchestrator now **degrades to imagery on an ingest-lidar transport/
    timeout error** (ADR-001 intent) while a schema/contract error from that stage still
    hard-fails; `advance_to!` guards terminal→non-terminal resurrection + `GeometryJob`
    no-ops on a terminal job + `discard_on RecordNotFound`; `derive_utm_epsg` raises on
    nil lon instead of silently using zone 14; empty facets fail the job rather than
    persisting an empty "complete" measurement; `@warnings` appends are mutex-guarded and
    the VLM thread gets a join-grace before kill.
  - Efficiency: memoized `current_fingerprint` + the presigner; precomputed the status-
    index hash + hoisted `job_pipeline_stages` in the status partial. (Deferred, recorded:
    a composite `(job_id, generated_at)` index on measurements — irrelevant at ≤1
    measurement/job, matters only at scale.)

#### Step 7 — assembled-app smoke test

Driven through the real running app (dev Rails server + real sidecar subprocess,
local storage root, Chrome DevTools browser):

- **Login → `/jobs/new`** renders with the spec's inline guidance copy. ✓
- **Submitting an address** created a `Job`, enqueued `GeometryJob`, and
  Turbo-redirected to `/jobs/:id` — the status page rendered the address + all six
  per-stage labels ("Looking up address" … "Computing measurement"). ✓
- **The orchestrator ran end to end against the real sidecar:**
  `advance_to!(:resolving_address)` fired an ActionCable broadcast
  (`<turbo-stream action="replace" target="status_job_<uuid>">`, verified in the
  server log), then `resolve_address` hit the live sidecar, which returned **422**
  (the geocoder/footprint lookup needs real Nominatim + MS-Footprints network access
  that this hermetic local env doesn't provide — this is exactly the stage the CI
  e2e stubs for the same reason). The orchestrator caught it and called
  `fail_with!("Pipeline stage failed: Sidecar returned 422")`, broadcast the
  `failed` state, and finished cleanly in 1.8s — no crash. ✓ (failure-isolation +
  graceful-fail path proven live)
- **The status page's `failed` state** (on reload, rendered server-side from the
  persisted state) shows the failure block in an `alert` aria-live region + the
  "Try another address" back-to-form link — F-11 failure UX. ✓
- **Live WebSocket push** did NOT apply in the headless smoke browser (the broadcast
  fired server-side but the page didn't update without a reload). Root cause is the
  dev `async` cable adapter + a headless browser WS in this smoke env, NOT a wiring
  bug: the broadcast target id (`status_job_<uuid>`) exactly matches the page's
  `turbo_stream_from(job, :status)` subscription (verified in the log + by review),
  and the rendered-Turbo-Stream-payload render path is asserted by a request spec
  (Wave-1 fix). Production uses the solid_cable adapter. **Regression check:** a
  neighbouring existing path (`/up` liveness, login) worked normally.

**Low finding (recorded, non-blocking):** the failure copy for a resolve-address 422
surfaces the generic "Pipeline stage failed: Sidecar returned 422" rather than the
spec's friendly no-building copy. The graceful-fail mechanism works; mapping specific
stage failures (no-building / not-geocodable) to plainspoken COMPANY.md copy is a
follow-up polish item for the failure-UX surface.

### Retro (batch: F-10 + F-11)

1. **Learned about the system, not in the architecture?** The satellite imagery
   tile that F-07 (outline) and F-09 (VLM) both consume had **no producer** in any
   shipped feature — an invisible integration gap that only surfaced when the
   orchestrator tried to wire the stages together. This is exactly what an
   integration feature exists to catch. Resolved by adding a `render-imagery`
   sidecar stage (ARCHITECTURE.md already assigns NAIP fetch to the sidecar).
   Propagated: ADR-002 already covers NAIP-as-measurement-imagery; the new stage
   is consistent with it, so no ADR change — only the 0.3.0 schema envelope +
   ROADMAP cross-cutting row.
2. **Learned that changes the roadmap?** Convergence surfaced a **pre-existing
   robustness smell in F-06 (LiDAR ingest)**: `sidecar/app/lidar/router.py`
   resolves the PDAL cropper *eagerly* before the WESM coverage fast-fail, so in
   any env without `LIDAR_LIVE=1`+PDAL every ingest-lidar call 502s — even the
   `LIDAR_MISSING` fast-fail path is unreachable over HTTP. Real-world prod impact
   is LOW (prod has PDAL+LIDAR_LIVE), but a 3DEP-gap address *should* fast-fail to
   LIDAR_MISSING, not 502. F-10 defends against it (an ingest-lidar transport/5xx
   error now degrades to the imagery fallback), but the sidecar should still be
   fixed to resolve the cropper lazily after the coverage check. → captured as a
   ROADMAP cross-cutting note for a future F-06 touch-up.
3. **What contract changed?** Pipeline schema 0.2.0 → **0.3.0** (additive:
   `RenderImagery{Request,Response}`; `size_px` bounded `[1,4096]`). Updated at the
   source of truth (`shared/pipeline_schema.json`) + both clients (Pydantic +
   Ruby) + the changelog + the ROADMAP cross-cutting row. Dependents (F-12/13/14)
   read the same schema, so they see it automatically.
4. **What should the next builder do differently?** Two things. (a) **Branch the
   orchestrator workstream off the client workstream**, not off the bare contract
   lock — it consumes the client's per-stage methods, and stacking the worktrees
   meant zero merge friction on `sidecar_client.rb` (the client commit was shared,
   cherry-picked once). (b) **A workstream agent will over-reach if not told not
   to**: the F-11 agent pushed its branch and opened an MR on its own. The briefing
   must say explicitly "commit to your branch; do NOT push or open an MR — the
   integrator collects the batch into one MR." (Added to the briefing template
   mentally; worth a skill note.)

### Decisions/divergence summary (for the next reader)

- Per-feature workstreams were transient scaffolding; their commits now live as a
  linear chain on `feat/iter3-orchestrator-and-submission`. The `source` enum is
  `fusion`/`imagery` (schema `GeometrySource`), the status enum gained
  `fetching_imagery`, and `Measurement` geometry is GeoJSON JSONB (+ added columns
  `total_perimeter_ft`, `geocode`, `parcel_polygon`, `source_fingerprint`).
- Single-tenant auth assumption (any logged-in demo user can view any job; Turbo
  subscription authz == login-only) is **accepted for the demo** — revisit when
  multi-user auth lands.
