# Roadmap — RoofTrace

**Status:** agreed (v1) · **Date:** 2026-05-27 (v1) · 2026-05-31 (iOS-full-featured track added) · **Source:** [ARCHITECTURE.md](./ARCHITECTURE.md), [COMPANY.md](./COMPANY.md), [ADRs](./adrs/)

## Overview

RoofTrace is a roof-measurement system for CompanyCam contractors,
sliced into **19 features across six tracks** (v1): a Walking-Skeleton-first
foundation, three foundational contracts (pipeline schema, auth, brand
assets), four parallel geospatial-pipeline features that converge on a
**measurement-orchestrator integration feature**, three parallel app-layer
features (submit, web viewer, PDF, JSON export), a two-feature iOS track
whose backend half is a second **fusion integration feature**, two stretch
features depending on the integrations, and a standalone validation
harness. **Delivery strategy:** deploy the empty stack to the droplet on
Day 1; build the pipeline + app tracks in parallel after contracts land;
two explicit integration features (F-10 and F-16) are where parallelism
re-synchronizes.

**Post-v1 expansion — the full-featured iOS app (F-20–F-26, added 2026-05-31).**
v1 shipped a *thin* iOS app (F-15): a LiDAR capture harness reached by a
`capture_token` handed off from the web. This track makes the iOS app
**full-featured** — a contractor does **everything the web does, natively**:
sign in, see a list of their jobs, start a job by entering an address (native
MapKit typeahead) or detecting their location, watch the pipeline run live,
optionally do the existing guided LiDAR capture **inside the app**, and view the
finished report in a native MapKit + SwiftUI viewer. It is one **backend feature**
(F-20: the mobile JSON API — sessions/jobs-index/job-status endpoints) plus six
**iOS features** (F-21 foundation+login, F-22 job list, F-23 new-job, F-24 live
status, F-25 relocate capture, F-26 native report). The backend endpoints are the
critical-path dependency, but every iOS screen is built and unit-tested against a
**fake `APIClient`** in parallel with the backend work (see ADR-007 amendment).
Architecture decisions are locked in the **ADR-007 amendment** (navigation,
networking, polling-not-ActionCable, the glob-based `gen_pbxproj` refactor), the
**ADR-016 amendment** (the mobile app bearer-token auth surface), and **ADR-020**
(native two-palette design system + light-only v1). The frozen
`json_export.schema.json` (ADR-015) is already shipped, so the native report
viewer builds against a stable contract with no backend dependency.

## Project Pieces

| ID | Piece | Purpose | Depends on | Unblocks | Parallel with |
|----|-------|---------|-----------|----------|---------------|
| F-01 | Walking skeleton on the droplet | Rails + sidecar + Postgres deployed via Kamal to `rooftrace.biograph.dev`; one endpoint round-trips Rails → sidecar → Rails returning a hardcoded measurement | — | F-02, F-03, F-04, all others transitively | — |
| F-02 | Pipeline JSON Schema contract | `shared/pipeline_schema.json` defines the Rails↔sidecar request/response shape; types for both languages | F-01 | F-05, F-06, F-07, F-08, F-09, F-10, F-14 | F-03, F-04 |
| F-03 | Auth machinery | Dev login + share-token + iOS capture-token; sessions, controllers, model columns | F-01 | F-11, F-12, F-15, F-16 | F-02, F-04 |
| F-04 | Brand assets + shared report stylesheet | RoofTrace wordmark, palette, print + screen CSS in `app/assets/` consumed by viewer and PDF | F-01 | F-12, F-13, F-17 | F-02, F-03 |
| F-05 | Address & polygon resolver | Geocode (Nominatim) + MS Building Footprints + Regrid parcel, cached via Rails into PostGIS | F-01, F-02 | F-10 | F-06, F-07, F-08, F-09 |
| F-06 | LiDAR ingest | WESM coverage check + COPC streaming + PDAL crop to building points; emits NumPy point array in local UTM | F-01, F-02 | F-10 | F-05, F-07, F-08, F-09 |
| F-07 | Outline refinement | SAM2 zero-shot with footprint prior, Modal serverless + local-CPU fallback, Douglas–Peucker simplification | F-01, F-02 | F-10 | F-05, F-06, F-08, F-09 |
| F-08 | Plane fit + measurement | RANSAC multi-plane fit on cropped LiDAR points; pitch from normals, area from projected extent; emits facet list | F-01, F-02 | F-10 | F-05, F-06, F-07, F-09 |
| F-09 | VLM feature detection (Rails) | RubyLLM → VLM (v1 starting impl, behind a swappable `FeatureDetector` interface) with verification pass; emits structured detections; production model chosen by the F-19 eval | F-01, F-02 | F-10, F-19 | F-05, F-06, F-07, F-08 |
| **F-10** | **Integration: measurement orchestrator** | GeometryJob in Solid Queue chains F-05 → F-06 → F-07 → F-08 + parallel F-09; assembles unified measurement; handles LiDAR-missing fallback | F-05, F-06, F-07, F-08, F-09 | F-12, F-13, F-14, F-16, F-18, F-19 | F-11 |
| F-11 | Job submission flow | Address-entry form, Solid Queue enqueue, ActionCable status Turbo Streams | F-01, F-03 | F-12 | F-05–F-10 |
| F-12 | Web report viewer | Hotwire page + React island, MapLibre basemap, deck.gl facet extrusion, feature pins | F-01, F-03, F-04, F-10, F-11 | — | F-13, F-14 |
| F-13 | PDF report | Grover + Rails template + sidecar map-image render; baseline measurement PDF | F-01, F-04, F-10 | F-17 | F-12, F-14 |
| F-14 | JSON export | `/api/v1/jobs/:id.json` endpoint, schema-validated against `shared/json_export.schema.json` | F-01, F-02, F-10 | — | F-12, F-13 |
| F-15 | iOS capture app | Swift Xcode project; guided walk-around UX; ARKit world-mesh + depth + photos + GPS+IMU; multipart upload | F-01, F-03 | F-16 | F-05–F-10 |
| **F-16** | **Integration: iOS capture ingest + ICP fusion** | Rails ActiveStorage ingest + FusionJob in sidecar that ICP-aligns ARKit mesh to public-LiDAR points and re-runs plane fit | F-10, F-15 | F-17, F-18 | — |
| F-17 | Stretch: claim-defensibility PDF | Methodology footnote, visit-verified block, evidence photos, signature line, construction-doc chrome | F-13, F-16 | — | F-18 |
| F-18 | Stretch: server-side AR overlay | Pinhole projection of facets onto captured photos with z-buffer occlusion; surfaces in viewer + PDF | F-10, F-16 | — | F-17 |
| F-19 | Accuracy validation harness | (a) Measurement: 15 LiDAR-covered + 3 ground-truth addresses; MAPE + P90 + structural validity. (b) Feature detection: pull + hand-label a roof-tile dataset (production imagery provider, target GSD, diverse incl. true-negatives); per-class precision/recall + bbox IoU run across each candidate model behind the `FeatureDetector` interface to pick the production model. Generates `docs/VALIDATION_REPORT.md` | F-09, F-10 | — | (anytime after F-10) |
| **F-20** | **Mobile JSON API** | Backend. New mobile-auth endpoints so a native client can do what the web does: `POST /api/v1/sessions` (demo creds → app bearer token), `GET /api/v1/jobs` (index for the signed-in contractor), `GET /api/v1/jobs/:id` (job + live status, bearer), `POST /api/v1/jobs` JSON create (returns `job_id` + `capture_token`), and bearer access to `GET /api/v1/jobs/:id.json`. Per ADR-016 amendment. | F-03, F-10, F-14 | F-21, F-22, F-23, F-24, F-26 | F-21 |
| **F-21** | **iOS foundation + login** | The `gen_pbxproj` glob refactor; the design system (`Color.CC.*`/`Color.Brand.*`, Archivo+Inter, the component kit) per ADR-020; the actor `APIClient`+`Endpoint`+`APIError`+DTOs; `KeychainTokenStore`+`AuthStore`; the `NavigationStack`+`AppRouter` shell; and the **login screen** (POSTs `/api/v1/sessions`, stores the bearer). First consumer of the design system. Per ADR-007 + ADR-020 amendments. | F-15, F-20 | F-22, F-23, F-24, F-25, F-26 | — |
| **F-22** | **iOS job list / home** | The post-login home: a list of the contractor's jobs with status pills + the hero area number, pull-to-refresh, confident empty state, and the pinned "＋ New measurement" CTA. Consumes `GET /api/v1/jobs`. | F-21 | F-23, F-24 | F-23 |
| **F-23** | **iOS new measurement (MapKit address entry)** | Start a job from the app: native `MKLocalSearchCompleter` typeahead + a "use my location" affordance (`CLGeocoder`/CoreLocation) → `POST /api/v1/jobs` → receive `job_id`+`capture_token`, push to status. | F-21, F-22 | F-24 | F-22 |
| **F-24** | **iOS live status** | Watch the pipeline run: poll `GET /api/v1/jobs/:id` (2 s → backoff 15 s, cancel on disappear) and render the stage timeline (done/active/pending) → on `ready`, offer "View report" and (optionally) "Improve with a scan"; on `failed`, show a recoverable error. | F-21, F-23 | F-25, F-26 | — |
| **F-25** | **iOS capture, relocated in-app** | The existing 8-prompt LiDAR walk-around (F-15) now flows **inside** the app — entered from a job's status/detail with the `job_id`+`capture_token` already in hand (a `CaptureHandoff` value), not a token-entry screen + deep link — and restyled onto the design system. Capture payload/manifest UNCHANGED. | F-21, F-24 | — | F-26 |
| **F-26** | **iOS native report viewer** | A fully native MapKit + SwiftUI report: footprint + per-facet polygons (muted, instrument-style) on the map, the measurement tables (area, perimeter, per-facet pitch, features, confidence, warnings, attributions) in SF Mono, and a share action for the `/r/:token` link. Consumes the frozen `json_export.schema.json` (ADR-015) via `GET /api/v1/jobs/:id.json`. | F-21, F-20 | — | F-25 |

## Dependency Graph

```mermaid
graph TD
  F01[F-01 Walking skeleton on droplet]

  F02[F-02 Pipeline JSON Schema]
  F03[F-03 Auth machinery]
  F04[F-04 Brand assets + stylesheet]

  F05[F-05 Address & polygon resolver]
  F06[F-06 LiDAR ingest]
  F07[F-07 Outline refinement / SAM2]
  F08[F-08 Plane fit + measurement]
  F09[F-09 VLM feature detection]

  F10[F-10 INTEGRATION: Measurement orchestrator]

  F11[F-11 Job submission flow]
  F12[F-12 Web report viewer]
  F13[F-13 PDF report]
  F14[F-14 JSON export]

  F15[F-15 iOS capture app]
  F16[F-16 INTEGRATION: iOS ingest + ICP fusion]

  F17[F-17 Stretch: claim PDF]
  F18[F-18 Stretch: AR overlay]
  F19[F-19 Validation harness]

  F01 --> F02
  F01 --> F03
  F01 --> F04

  F02 --> F05
  F02 --> F06
  F02 --> F07
  F02 --> F08
  F02 --> F09
  F02 --> F14

  F05 --> F10
  F06 --> F10
  F07 --> F10
  F08 --> F10
  F09 --> F10

  F03 --> F11
  F11 --> F12
  F10 --> F12
  F04 --> F12

  F10 --> F13
  F04 --> F13

  F10 --> F14

  F03 --> F15
  F15 --> F16
  F10 --> F16

  F13 --> F17
  F16 --> F17
  F04 --> F17

  F10 --> F18
  F16 --> F18

  F10 --> F19

  classDef integration fill:#ff9933,stroke:#cc6600,stroke-width:3px,color:#000
  classDef stretch fill:#cce5ff,stroke:#0066cc,stroke-width:2px
  class F10,F16 integration
  class F17,F18 stretch
```

The two **orange integration nodes (F-10 and F-16)** are where parallel
tracks re-synchronize. Both have acceptance criteria written against
the *combined* behavior of their inputs, not the individual pieces.

### iOS-full-featured track (F-20–F-26, added 2026-05-31)

```mermaid
graph TD
  F03[F-03 Auth machinery]
  F10[F-10 Measurement orchestrator]
  F14[F-14 JSON export]
  F15[F-15 iOS capture app]

  F20[F-20 Mobile JSON API]
  F21[F-21 iOS foundation + login]
  F22[F-22 iOS job list]
  F23[F-23 iOS new measurement]
  F24[F-24 iOS live status]
  F25[F-25 iOS capture relocated]
  F26[F-26 iOS native report]

  F03 --> F20
  F10 --> F20
  F14 --> F20

  F20 --> F21
  F15 --> F21

  F21 --> F22
  F21 --> F23
  F21 --> F24
  F21 --> F25
  F21 --> F26

  F22 --> F23
  F23 --> F24
  F24 --> F25
  F20 --> F26

  classDef backend fill:#cce5ff,stroke:#0066cc,stroke-width:2px
  class F20 backend
```

**The genuinely-serial spine** of this track is
**F-20 → F-21 → F-22 → F-23 → F-24 → F-25**, but the hard deps are real and
minimal: F-21 needs the auth/jobs/status endpoints to *exist* (F-20) and the
existing capture code to *relocate* (F-15); each screen needs the foundation
(F-21). **Concurrency the build can exploit:** F-20 (backend) and F-21 (iOS
foundation) build **at the same time** — F-21's screens run against a fake
`APIClient` until F-20 lands (ADR-007 amendment). F-26 (native report) depends
only on F-21 + the *already-shipped* `json_export.schema.json` contract via F-20's
bearer pass-through, so it can be built early against the frozen schema rather
than waiting on the F-22→F-25 chain. F-25 (relocate capture) is mostly a *move +
re-seam* of shipped F-15 code and is low-risk despite sitting late in the chain.

## Critical Path

**F-01 → F-02 → F-06 (LiDAR ingest) → F-10 → F-16 → F-18.**

This is the longest dependency chain in the graph — it determines the
minimum schedule, end-to-end.

- **F-01** must land first (everything else needs the deployed stack).
- **F-02** is the contract every pipeline feature reads; lock it before
  the pipeline track diverges so 4 agents don't write 4 incompatible
  schemas.
- **F-06 (LiDAR)** is the longest of the four pipeline features
  (geocode/polygons F-05 is faster; SAM2 F-07 is bounded by Modal
  setup; plane-fit F-08 is bounded by RANSAC tuning; VLM F-09 is a
  RubyLLM call). LiDAR includes the WESM coverage check, COPC streaming,
  CRS reprojection, and PDAL pipeline composition — historically eats
  ~1 day even for a skilled geospatial dev. **This is the
  schedule-determining feature in the pipeline track.**
- **F-10 (orchestrator integration)** can only start once all five
  pipeline features have a working contract; it has the highest
  *coordination* risk because contract drift across the four
  parallel pipeline features lands here.
- **F-16 (iOS fusion integration)** requires both the iOS app
  (F-15) and the orchestrator (F-10). The orchestrator is usually
  ready first since the iOS track tends to take longer.
- **F-18 (AR overlay stretch)** depends on F-16; it is the final
  feature on the critical path and the most-visible demo moment.
  Easy to defer if behind schedule.

**Convergence points to watch:**

1. **F-10 (measurement orchestrator).** Five inputs (F-05–F-09)
   produce a unified measurement. Risk: contract drift across
   parallel pipeline features. Mitigation: F-02 (the JSON Schema)
   is the single source of truth; every pipeline feature validates
   its output against the schema as part of its acceptance.
2. **F-16 (iOS fusion integration).** Two inputs (F-10 + F-15)
   in different languages and stacks. Risk: ARKit mesh coordinate-
   frame disagreement with the public-LiDAR cloud (the whole point
   of ICP). Mitigation: F-16's acceptance demands a numerical
   alignment-error metric below threshold on a fixture session.

## Parallelization Plan

### Wave 0 — Bootstrap (1 agent, blocks everything)

- **F-01** Walking skeleton.

### Wave 1 — Contracts & foundation (3 agents in parallel)

After F-01 lands, three independent agents can start:
- **F-02** Pipeline schema (will unblock the geospatial pipeline track).
- **F-03** Auth machinery (will unblock the app + iOS tracks).
- **F-04** Brand assets + report stylesheet (will unblock viewer + PDF).

### Wave 2 — Parallel construction (up to 7 agents in parallel)

Once Wave 1's contracts are in place:

**Geospatial pipeline track (5 agents possible, all parallel):**
- F-05 Address & polygon resolver
- F-06 LiDAR ingest **← critical path**
- F-07 Outline refinement (SAM2)
- F-08 Plane fit + measurement
- F-09 VLM feature detection (Rails)

Each consumes the F-02 schema; each is self-contained behind its
contract. The Python sidecar tracks (F-05, F-06, F-07, F-08) all
share `sidecar/`; minor coordination on common deps but no overlap on
business logic. F-09 lives in Rails (RubyLLM per ADR-006).

**App-layer track (2 agents possible, parallel with the pipeline):**
- F-11 Job submission flow (form + Solid Queue + ActionCable)
- F-15 iOS capture app (Swift) — parallel with everything else;
  longest single-agent feature.

### Wave 3 — Integration & user surfaces (after F-10 lands)

The orchestrator (**F-10**) is the first integration. Once green:
- **F-12** Web report viewer (consumes F-10 output)
- **F-13** PDF report (consumes F-10 output)
- **F-14** JSON export (consumes F-10 output)
- **F-19** Validation harness (consumes F-10; can run in parallel
  with the surfaces)

These four can run in parallel.

### Wave 4 — iOS integration (after F-10 + F-15)

- **F-16** iOS capture ingest + ICP fusion. Unblocks both stretches.

### Wave 5 — Stretches (after F-16, parallel)

- **F-17** Claim-defensibility PDF (consumes F-13, F-16)
- **F-18** Server-side AR overlay (consumes F-10, F-16)

### What a fresh agent needs before starting

- For any pipeline feature (F-05–F-09): read
  `ARCHITECTURE.md`, the relevant ADRs, the pipeline schema
  `shared/pipeline_schema.json`, and run the F-01 walking skeleton
  locally to confirm the IPC boundary works.
- For app-layer features (F-11–F-14): read ARCHITECTURE.md, F-03's
  auth surface, F-04's brand contract, and F-10's output shape.
- For iOS work (F-15): read [ADR-007](./adrs/ADR-007-mobile-capture-thin-ios-app.md)
  in full; confirm Pro iPhone hardware availability or commit to
  fixture-driven dev.
- For stretches (F-17, F-18): the relevant integration feature
  (F-16) must be merged and a fixture iOS session must exist in
  `spec/fixtures/`.

## Cross-Cutting Concerns

| Concern | Source of truth | Rule features must follow |
|---|---|---|
| **CompanyCam brand & voice** | [COMPANY.md §Brand & voice](./COMPANY.md) | All user-facing copy and UI must match the contractor-respectful, plainspoken trade-magazine register. Color use: orange as primary CTA only; charcoal text on white; muted grays for confidence/secondary. |
| **Pipeline contract** | `shared/pipeline_schema.json` (delivered by F-02; per-stage envelopes added in F-05–F-09 @ 0.2.0; `RenderImagery*` added in F-10 @ 0.3.0) | Every Rails↔sidecar call validates request and response against this schema. Schema changes are PRs that bump the contract version and update both clients. Per-stage shapes (`ResolveAddress*`, `IngestLidar*`, `RefineOutline*`, `RenderImagery*`, `FitPlanes*`/`MeasurementGeometry`, `DetectFeatures*`) live here, not as ad-hoc per-feature shapes. |
| **Blob-reference convention** *(F-06/F-07/F-08/F-09)* | `shared/pipeline_schema.json` + [ADR-010](./adrs/ADR-010-blob-storage-do-spaces.md) | Point clouds and image tiles **never cross the contract inline** — they cross as a **Spaces object key** (`point_array_ref`, `image_tile_ref`) in the one prefixed bucket. The orchestrator (F-10) mints a short-lived signed URL when a stage must fetch one. A stage that needs bytes uses `sidecar/app/storage.py` (`get_bytes`/`put_bytes`), which refuses keys escaping the local root. |
| **Cropped point-array layout** *(F-06 → F-08, learned at convergence)* | F-06 `ingest.py` (producer) | The `.npy` referenced by `point_array_ref` is **`(N, 4)` `[x, y, z, classification]`** in the local UTM zone, class pre-filtered to ASPRS-6. Consumers (F-08, F-16) must take `[:, :3]` for geometry. The contract carries only the opaque ref, so this layout is the convention every consumer follows. *(A 3-vs-4-column mismatch broke F-08 at integration; this row exists so the next consumer doesn't repeat it.)* |
| **`utm_zone` is a full EPSG code** *(F-06 → F-08, learned at convergence)* | `shared/pipeline_schema.json` (`IngestLidarResponse.utm_zone`, `FitPlanesRequest.utm_zone`) | The `utm_zone` field is the **full WGS84/UTM EPSG code** (e.g. `32614`), NOT a 1–60 zone number. Consumers transform vertices back to WGS84 with it directly. *(F-08 initially did `32600 + utm_zone` → `EPSG:65214`; caught at integration.)* |
| **JSON export contract** | `shared/json_export.schema.json` (delivered by F-14) + [ADR-015](./adrs/ADR-015-json-export-schema-versioned.md) | Versioned semver; v1.x additive only; v2.x reserved for breaking changes; one fixture validates in CI. |
| **Report row creation** | [ADR-016](./adrs/ADR-016-auth-dev-login-plus-share-tokens.md) | A job's shareable `Report` (the `/r/:token` access grant) is minted by the **measurement orchestrator** when the job reaches `:ready`, **after the measurement transaction commits** (NOT inside it — a `RecordNotUnique` from a concurrent creator racing the `reports.job_id` unique index would otherwise roll back the measurement + `:ready` flip and discard completed pipeline work). Use the race-safe helper `find_or_create_by!(job:) rescue RecordNotUnique → find_by!(job:)` (`find_or_create_by!` alone does not rescue it); the contractor viewer mirrors it. The public report surfaces (HTML viewer, PDF, JSON export) resolve token → job → `latest_measurement` and never mint a Report themselves. A not-ready job (nil measurement) — or a token whose Report predates a measurement — degrades to a not-ready response (HTML) / a `200` with `null` measurement + `null` artifact URLs (JSON), **never a `500`**. |
| **JSON export public-share identity** | [ADR-015](./adrs/ADR-015-json-export-schema-versioned.md), [ADR-016](./adrs/ADR-016-auth-dev-login-plus-share-tokens.md) | `GET /api/v1/jobs/:id.json` (auth) and `GET /r/:token.json` (public) return the **identical** `JobExportSerializer` output. The only differences are the access-failure mode — `401` (not a `302`, so non-redirect-following tools fail cleanly) vs a token-gate `404` — and CORS (none on the auth route; `Access-Control-Allow-Origin: *` on the public route). No redaction, no route-conditional serializer branches. |
| **CRS discipline** | [ADR-003](./adrs/ADR-003-lidar-source-usgs-3dep-copc.md), [ADR-004](./adrs/ADR-004-footprint-source-ms-building-footprints-regrid.md) | All polygons stored as WGS84 (SRID 4326); reprojected to local UTM for area math. PostGIS `geography` type for spherical sanity. Areas in m² (converted to sq ft only at the presentation boundary). **Any windowed raster read must reproject the WGS84 query bounds into the raster's *own* CRS first** — NAIP/most COGs are stored in projected UTM, so passing lon/lat degrees against the source transform reads the wrong pixels (`rasterio.warp.transform_bounds("EPSG:4326", src.crs, …)` before `windows.from_bounds`). *(Caught in the F-10 imagery-stage review.)* |
| **Honest uncertainty UX** | [COMPANY.md §Concrete design guidance](./COMPANY.md), [ADR-001](./adrs/ADR-001-geometry-architecture-sat-lidar-fusion.md), [ADR-006](./adrs/ADR-006-feature-detection-vlm-primary.md) | Every measurement carries `source` + `confidence`; UI surfaces method ("from LiDAR" / "from imagery" / "from your photo capture"); never hide low-confidence results, mark them. |
| **Confidence-aware artifact propagation** | [ADR-015](./adrs/ADR-015-json-export-schema-versioned.md) | `source` and `confidence` propagate from sidecar → Rails → JSON export → PDF report. No surface drops them. |
| **Auth boundary** | [ADR-016](./adrs/ADR-016-auth-dev-login-plus-share-tokens.md) (delivered by F-03) | All submit routes gated by `require_demo_login`; share routes (`/r/:token`) public, read-only, `noindex`; iOS *capture-upload* route gated by short-lived bearer token scoped to one job. |
| **Mobile app bearer auth** *(F-20 → F-21/F-22/F-23/F-24/F-26)* | [ADR-016 amendment](./adrs/ADR-016-auth-dev-login-plus-share-tokens.md) (introduced by F-20) | A **fourth** auth surface: the iOS app self-authenticates via `POST /api/v1/sessions` (demo creds → opaque `has_secure_token`-style app bearer, DB-unique-indexed, TTL), stored in the iOS Keychain (`…AfterFirstUnlockThisDeviceOnly`), sent as `Authorization: Bearer …` on `GET /api/v1/jobs`, `GET /api/v1/jobs/:id`, `POST /api/v1/jobs` (JSON), `GET /api/v1/jobs/:id.json`. **Distinct from the per-job `capture_token`** (which still authenticates the capture upload — never the app token). Missing/expired bearer → `401` (NOT a `302` redirect) so the native client fails cleanly; the app clears the token and re-logs-in on `401`. |
| **iOS API client contract** *(F-21 introduces; F-22/F-23/F-24/F-26 extend)* | [ADR-007 amendment](./adrs/ADR-007-mobile-capture-thin-ios-app.md) | ONE `actor APIClient` (typed `Endpoint<Response>`, single-point bearer injection, `APIError` status mapping, snake_case `Codable` DTOs) is the only JSON transport for the mobile read/write endpoints; the streamed `MultipartUploader` stays **separate** for the capture-bundle upload. Every screen is built + unit-tested against a **fake `APIClient`**, so iOS work proceeds in parallel with F-20. The job lifecycle is decoded into a make-illegal-states-unrepresentable enum (`pending`/`processing(Stage)`/`ready(ReportLocator)`/`failed(reason)`) at the boundary; the UI never sees a raw status string. |
| **iOS native design system (two-palette)** *(F-21 introduces; F-22–F-26 extend)* | [ADR-020](./adrs/ADR-020-ios-native-design-system-light-only.md) | Native mirror of the web two-palette system: `Color.CC.*` (entry surfaces — login, list, new-job, status, capture) and `Color.Brand.*` (report surface only), as asset-catalog Color Sets; bundled Archivo (display) + Inter (body), SF Mono for ALL measurements; a ~14-component kit built once. **The palettes must never cross** (no `Brand.*` on an entry surface, no `CC.*` in the report). **Light-only v1** (`.preferredColorScheme(.light)`) — do NOT add auto dark mode (paper-document identity + sunlight legibility). Orange is never body-size text (AA); confidence never rides on color alone. |
| **iOS report decode: facet-vertex `[lat,lng]` flip** *(F-26)* | `shared/json_export.schema.json` v1.1.0 + [ADR-015](./adrs/ADR-015-json-export-schema-versioned.md) | In the JSON export, facet `vertices` are **`[lat, lng]` (flipped, insurance convention)** while `roof_outline`/`footprint` GeoJSON are standard **`[lng, lat]`**. The native viewer MUST interpret these through TWO distinct, unit-tested functions (`coordFromFacetVertex` vs `coordFromGeoJSON`) — a single shared converter silently transposes a roof into the ocean. Malformed/`null` vertices drop out (optional-honest), and a `200`-with-`null`-measurement degrades to a not-ready state, never a crash. |
| **Outbound-URL SSRF** *(F-09 review; applies to any stage that hands a URL to an external fetcher)* | This row | Any URL we pass to a third party that fetches it server-side (Gemini image fetch today; any future VLM/tile fetcher) MUST be host-allowlisted — scheme `https` + an allowlisted host suffix (the Spaces CDN; env-overridable) — *before* it's sent. Reject loopback / link-local (169.254.x metadata) / `file:`. A storage `*_ref` + an internally-minted signed URL is preferred over accepting a caller URL. Brief the security review with this lens. |
| **External-secret transport** *(F-09/F-05 review)* | This row | Provider API keys go in **headers**, never the URL query string (Gemini → `x-goog-api-key`). Where a provider mandates a query-param token (Regrid free tier), keep it out of exception messages/logs — report the error class, not the URL. |
| **Pipeline-stage env config fail-fast** *(F-06 review; owned by F-10 + deploy)* | [ADR-011](./adrs/ADR-011-deploy-kamal-do-droplet.md) consequences | A stage whose live path needs env config (F-06: `LIDAR_LIVE` + `WESM_GPKG_PATH`; storage: `STORAGE_*`) currently resolves it lazily per-request, so a misconfigured deploy boots green then 502s every call. F-10/deploy must wire these in `ops/compose.prod.yaml` + `ops/.env.example` and **fail fast at sidecar boot** when a pipeline stage is enabled but its config is missing — matching the Rails `after_initialize` raise-in-prod pattern. *(Done in the F-10 batch: `ops` env wired + `sidecar/app/boot_checks.py` raises at boot under `SIDECAR_ENV=production`.)* This extends to **runtime library presence, not just env vars**: a stage whose live path needs a heavy import the image might not ship (imagery → `rasterio`) must (a) declare the dep so the image installs it and (b) have its boot check verify importability when its `*_LIVE` flag is set — else it boots green and 502s every call. *(F-10 imagery review: `rasterio` was missing from the image; added to deps + boot check.)* |
| **Job retry vs. terminal status** *(F-10 review; any ActiveJob driving a status state-machine)* | This row | A job that re-raises for the queue's bounded retry **must not** move its record to a terminal status (e.g. `failed`) before re-raising — if `perform` short-circuits on a terminal guard (`return if job.terminal?`), the retry becomes a silent no-op and the transient error permanently fails after one attempt. Pattern: keep the record non-terminal (record `last_error`) on intermediate attempts; only mark terminal on the final attempt (`executions >= attempts`). Distinguish *expected* failures (don't raise → stay terminal, no retry) from *unexpected* ones (raise → stay retryable until exhausted). **Brief the next robustness reviewer with this lens** — the adversarial pass that added the terminal guard is what introduced the retry-defeat. |
| **LiDAR ingest resolves the cropper eagerly** *(surfaced at F-10 convergence; future F-06 touch-up)* | `sidecar/app/lidar/router.py` | The ingest-lidar handler resolves the PDAL cropper *before* the WESM coverage fast-fail, so in any env without `LIDAR_LIVE=1`+PDAL **every** call 502s — even a 3DEP-gap address that should fast-fail to `LIDAR_MISSING`. Prod impact is low (prod has PDAL), but a gap address ought to degrade, not error. The orchestrator already defends against it (an ingest-lidar transport/5xx error degrades to the imagery fallback per ADR-001); the sidecar should resolve the cropper *lazily after* the coverage check so `LIDAR_MISSING` is reachable without PDAL. |
| **Storage organization** | [ADR-010](./adrs/ADR-010-blob-storage-do-spaces.md) | Four buckets with distinct retention/visibility: `uploads/` private + signed, `cache/` 30-day TTL, `artifacts/public/<token>/...` public-read, `backups/` lifecycle-retained. |
| **Per-prefix signed-URL minters** *(Wave 3 report/JSON surfaces)* | `app/services/{artifact,imagery}_url_minter.rb` + [ADR-010](./adrs/ADR-010-blob-storage-do-spaces.md) | Each signed-URL minter is **hard-locked to ONE key prefix** of the single bucket and raises on any other key (defense-in-depth so a report surface cannot sign a `cache/` imagery tile and vice-versa). `ImageryUrlMinter` → `cache/` only; `ArtifactUrlMinter` → `artifacts/` only (report PDF + rendered map PNG, default 24h TTL). `ArtifactStore` (head/put over `artifacts/`) enforces the same prefix. A new partition that needs signing gets its own prefix-locked minter — do NOT widen an existing one. |
| **Report-row eager creation on `:ready`** *(Wave 3 share surfaces; owned by the orchestrator)* | `app/services/measurement_orchestrator.rb` (`persist`/`ensure_report_for`) + [ADR-016](./adrs/ADR-016-auth-dev-login-plus-share-tokens.md) | A shareable `Report` (carrying the `/r/:token` share token) is minted eagerly when a job reaches `:ready`, **immediately AFTER the measurement transaction commits** — *not* inside it. The `reports.job_id` unique index means a concurrent creator (orchestrator vs. the contractor viewer) can lose the race with `RecordNotUnique`; inside the transaction that rollback would discard the Measurement + `:ready` flip, so the mint is post-commit through the race-safe `find_or_create_by!(job:) rescue RecordNotUnique → find_by!(job:)` helper (mirrored in `JobsController#ensure_report`). The public viewer, PDF, and JSON share surfaces all resolve `Report → job → latest_measurement`; `latest_measurement` is LIVE (newest by `generated_at`), never a snapshot. *(MR-!10 review: the original "inside the transaction" form was a measurement-loss bug; this row + ADR-016 are the corrected convention.)* |
| **Headless-render robustness** *(Wave 3 PDF/map-image review; any stage that screenshots a rendered page)* | This row | A headless screenshot stage (Playwright top-down map render; any future Grover/Puppeteer page) must (a) **not depend on a runtime CDN** for its render libraries — a slow/unreachable CDN otherwise yields a silently-blank screenshot at HTTP 200; bundle the lib into the image and load it `file://`/inline, or at minimum set a `window.__*Failed` flag and **raise** so the caller degrades to a deterministic placeholder rather than a featureless image; and (b) treat the synchronous-in-request render as a **v1-only** shape — cold headless-Chrome start makes the warm `<10s` budget structurally fragile under a small Puma/worker pool, so the documented upgrade is to move generation to an ActiveJob (202 + poll). *(MapLibre is currently fetched from unpkg at render time; the silent-blank path is now guarded by the `__mapFailed` flag, but vendoring the dist + the async upgrade remain the durable follow-ups — brief the next robustness reviewer with this lens.)* |
| **License & attribution** | `LICENSES.md` (created by F-01 / F-02 + maintained as new sources added) | NAIP, MS Footprints, Mapbox, Nominatim, Regrid all require attribution surfaces in viewer + PDF. |
| **Testing — visible-in-CI gate** | This roadmap (cross-cutting), each feature spec | Each feature ships with the tests named in its "Testing requirements" section. PRs must show green CI before merge. |
| **Demo set discipline** | [ADR-017](./adrs/ADR-017-accuracy-validation-harness.md) (delivered in F-19) | `sidecar/validation/test_addresses.yaml` is the single source of demo addresses; demo scripts pull from it. No ad-hoc addresses in the live demo. |
| **Deploy story** *(amended F-01)* | [ADR-011](./adrs/ADR-011-deploy-kamal-do-droplet.md) (delivered by F-01) | All services run as containers. **v1 deploy tool is docker-compose, NOT Kamal** (`ops/compose.prod.yaml` is the production source of truth). Deployed containers join the droplet's shared **`openemr_default`** network; the host's **containerized Caddy** (`openemr-caddy-1`) reverse-proxies to the web container **by name** (`rooftrace-web`) via a `*.caddyfile` drop-in in `/etc/caddy/conf.d/`. Postgres + sidecar stay on a private `internal` network. Any feature exposing HTTP follows this pattern (see `ops/README.md`). Kamal (`ops/deploy.yml`) is the documented future multi-host path. |
| **Documentation hygiene** | This file + per-ADR consequences sections | Architectural decisions land as ADRs (no in-feature ADRing); load-bearing implementation notes from a feature that affect *other* features must propagate to ARCHITECTURE.md or ROADMAP.md, not just sit in the feature file. |
| **No transient feature-IDs in permanent artifacts** | `CLAUDE.md` + the `kmaz-feature-builder` skill | Feature-file IDs (`F-NN`) are transient work-trackers; they get archived and become dangling noise. They must NOT appear in code comments, config, env templates, prompts, or committed docs (ADRs/ARCHITECTURE/ROADMAP/README/LICENSES/CLAUDE.md) — only in feature files, commit messages, and PR/MR bodies. A comment must stand on its own or reference a durable ADR. **OUTSTANDING FOLLOW-UP:** the convention is enforced going forward, but ~40 existing non-doc files still carry `F-NN` refs and need a one-pass cleanup (map each to its ADR where one fits, else delete): `shared/pipeline_schema.json`, `shared/PIPELINE_SCHEMA_CHANGELOG.md`, all of `sidecar/app/` + `sidecar/tests/`, `app/controllers/*`, `app/models/{job,report}.rb`, `app/services/spaces_health.rb`, `config/{routes,application,storage}.rb` + `db/migrate/*`, `ops/{README.md,compose.prod.yaml,deploy.yml}`, `LICENSES.md`, and several ADRs (008/009/010/011/013/016). (This ROADMAP and `docs/` are exempt — feature files live here.) |

## High-Level Acceptance Criteria

| ID | Done when … |
|----|---|
| F-01 | `kamal deploy` succeeds; `https://rooftrace.biograph.dev/health` returns 200; one demo endpoint round-trips Rails → sidecar → Rails and persists/reads one row in Postgres. |
| F-02 | `shared/pipeline_schema.json` exists; Rails-side serializer + Python-side Pydantic model both validate against it; CI runs the validation. |
| F-03 | Submit pages 302-redirect to `/login` when unauthenticated; `/r/:token` serves a public read-only stub; iOS capture endpoint rejects requests missing/expired bearer tokens. |
| F-04 | Wordmark + palette tokens in `app/assets/`; shared `report.scss` consumed by a stub viewer page and a stub PDF page; print-only sections gated by `@media print`. |
| F-05 | Given an address, returns geocoded lat/lng + parcel polygon + building polygons (intersected with parcel) in WGS84; caches Nominatim/Regrid/MS responses. |
| F-06 | Given a building polygon, returns either `(point_array_utm, work_unit_metadata)` or a `LIDAR_MISSING` signal with reason; works on 3 LiDAR-covered demo addresses and 1 known-gap address. |
| F-07 | Given an image tile + a prior polygon, returns a refined polygon (and an IoU vs. prior for sanity). Modal path and local-CPU path both pass the same test. |
| F-08 | Given a point cloud, returns a facet list with vertices (UTM), pitch (degrees + ratio), area (m²), and confidence; total area within ±3% of a fixture LiDAR-only ground-truth. |
| F-09 | Given a tile + a roof polygon, returns a structured detection list (label, bbox_norm, confidence, source) matching the JSON Schema; verification pass downgrades low-confidence detections. |
| F-10 | Submitting an address via the orchestrator produces a complete `Measurement` row composed of all five inputs; LiDAR-missing path produces a measurement with `source: imagery_only`; integration test covers both. |
| F-11 | Form submission enqueues a job, returns `201 { job_id }`, opens an ActionCable channel, and emits status updates ("pending" → "running" → "ready") at the right boundaries. |
| F-12 | Report page renders the satellite basemap, refined roof polygon, per-facet extrusion with pitch coloring, and feature pins; hover shows facet area + confidence; mobile-responsive. |
| F-13 | PDF download produces a valid PDF with header, address, headline measurements, sidecar-rendered roof diagram image, per-facet table, methodology footnote, attribution footer. |
| F-14 | JSON endpoint returns a document that validates against `shared/json_export.schema.json` and round-trips through `JSONSchema.validate` in CI. |
| F-15 | TestFlight build runs on a Pro iPhone; guided walk-around prompts cycle through 8 positions; capture session produces a single multipart POST containing photos, depth maps, ARKit mesh, GPS, IMU; an `Authorization: Bearer …` token is sent. |
| F-16 | An ingested iOS session triggers FusionJob; sidecar ICP-aligns ARKit mesh to public-LiDAR; alignment error reported in metadata; resulting measurement's `source` upgrades to `lidar+device+imagery` with raised confidence. |
| F-17 | PDF includes methodology footnote naming all data sources & dates, a GPS-verified visit block (when iOS session exists), 2–4 evidence photos, signature line, construction-document chrome. |
| F-18 | Each captured photo gets a composite image (photo + facet overlay SVG) generated server-side; appears in the viewer's "On-Site Visualization" section and in PDF; low-pose-confidence photos surface a warning instead of a broken overlay. |
| F-19 | `docs/VALIDATION_REPORT.md` exists with MAPE + P90 metrics over the 15-address test set, per-complexity breakdown, ground-truth comparison against the 3 controls, and a published list of test addresses. Includes the feature-detection model evaluation (per ADR-006): pulls + hand-labels a roof-tile dataset (production imagery provider, target GSD), then scores per-class precision/recall + bbox IoU across candidate models, with the production model selected by measured results. |
| F-20 | `POST /api/v1/sessions` with the demo credential returns an app bearer token (and `401` on a bad credential); `GET /api/v1/jobs` returns the contractor's jobs for a valid bearer and `401` (not `302`) for a missing/expired one; `GET /api/v1/jobs/:id` returns the job's address + live status; `POST /api/v1/jobs` (JSON) creates a job and returns `{job_id, capture_token, capture_token_expires_at}`; `GET /api/v1/jobs/:id.json` accepts the same bearer and returns the identical `JobExportSerializer` payload as the public route. Request specs cover each auth-failure mode. |
| F-21 | `xcodebuild` builds + the unit suite is green via the **glob-based** `gen_pbxproj.py` (adding a Swift file needs no list edit); the app launches to a **login screen** in the `cc-*` palette (Archivo hero, bundled fonts), signs in against `POST /api/v1/sessions`, stores the bearer in the Keychain, and lands on an (empty) `NavigationStack` home; a `401` returns to login. `APIClient`, `KeychainTokenStore`, `AuthStore`, and the design-system tokens/components exist and are unit-tested against fakes. Light-only is enforced. |
| F-22 | After login the home shows the contractor's jobs (address, status pill, ready-job area in mono, relative date), pull-to-refresh re-fetches, the empty state guides a first measurement, and a pinned "＋ New measurement" CTA opens the create flow. Built against a fake `APIClient`; verified against the live `GET /api/v1/jobs`. |
| F-23 | The new-measurement screen offers MapKit typeahead and "use my location"; selecting/entering an address and submitting calls `POST /api/v1/jobs`, and on success pushes to the live-status screen for the returned `job_id`. Geocode/no-result/permission-denied states are handled inline (no system alert for domain errors). |
| F-24 | Opening a job polls `GET /api/v1/jobs/:id` and renders the stage timeline advancing through the pipeline (done ✓ / active / pending), stops on `ready`/`failed`, offers "View report" on ready and a recoverable retry on failed, and cancels polling when the screen disappears. The lifecycle is decoded into the `JobStatus`/`Stage` enum (no stringly-typed status in the UI). |
| F-25 | From a job, the contractor can launch the guided LiDAR walk-around **without re-entering a token** (the `job_id`+`capture_token` flow in from the job), complete the 8 prompts, and upload — the existing capture payload/manifest unchanged, the upload still authenticated by the per-job `capture_token`. The flow is restyled onto the design system. The credential-handoff security property still holds (now via the typed `CaptureHandoff`). |
| F-26 | A ready job's report renders natively: a MapKit map with the roof footprint + per-facet polygons (muted single-hue, NOT a rainbow) + the measurement tables (area, perimeter, predominant + per-facet pitch, detected features, confidence in muted grays, warnings, attributions) in SF Mono, decoded from `GET /api/v1/jobs/:id.json`; a share action presents the `/r/:token` link; a `200`-with-null-measurement degrades to a not-ready state (never a crash). The facet-vertex `[lat,lng]` flip is consumed correctly (verified by a unit test). |
