# Feature: Mobile JSON API (sessions + jobs index + job status + JSON create)

**ID:** F-20 · **Roadmap piece:** F-20 · **Status:** Done

## What this delivers (before → after)

**Before:** The backend has no way for a native client to authenticate as the
contractor or read its jobs. The only mobile endpoint is the per-job
capture-bundle upload (`POST /api/v1/capture-sessions/:job_id`, gated by a
`capture_token`); everything else (job list, create, status, report) requires a
web **session cookie**, which a native client can't carry cleanly.

**After:** A native client can do everything the web does over a clean JSON
contract: obtain an **app bearer token** from the demo credential, list the
contractor's jobs, read one job's live status, create a job, and read the JSON
export — all authenticated by the bearer in an `Authorization` header.

## How it fits the roadmap

The backend half of the iOS-full-featured track and its critical-path
dependency. It builds **concurrently with F-21** (the iOS foundation), which
develops against a fake `APIClient` until these endpoints land. Per the
[ADR-016 amendment](../adrs/ADR-016-auth-dev-login-plus-share-tokens.md).

## Requirements traced (from the PRD)

Satisfies the "contractor can start a job and view results from mobile" capability
natively (the brief's Mobile-Assisted Capture + the web submit/status/report flow,
delivered to the native client). Reuses the v1 auth model (ADR-016) rather than
adding a user system.

## Dependencies (must exist before this starts)

- **F-03 Auth machinery** — the demo-login credential + `has_secure_token` +
  `capture_token` machinery this builds on.
- **F-10 Measurement orchestrator** — produces the `Measurement`/status the
  status + export endpoints read.
- **F-14 JSON export** — the `JobExportSerializer` + `json_export.schema.json` the
  bearer-gated `GET /api/v1/jobs/:id.json` reuses verbatim.

## Unblocks (what waits on this)

- **F-21, F-22, F-23, F-24, F-26** — every iOS screen that talks to the backend.
  (They build against a fake `APIClient` first, then point at these endpoints.)

## Contracts touched

- **Mobile app bearer auth** (source of truth: ADR-016 amendment) — *introduces*
  it. A new app session token (opaque, `has_secure_token`-style, DB-unique-indexed,
  TTL), distinct from the `capture_token`. The token store + `authenticate` lookup
  + the `before_action` that gates the mobile endpoints.
- **JSON export public-share identity** (ADR-015/ADR-016) — *extends*: adds a
  **bearer-gated** access path to the same `JobExportSerializer` output that the
  auth-session and public-token routes already return. Same payload, `401` (not
  `302`) on a missing/expired bearer.
- **iOS API client contract** (ADR-007 amendment) — this is the *server side* of
  the typed `Endpoint`s F-21 consumes; the field names/shapes here are what the
  Swift DTOs decode.

## Acceptance criteria (product behavior)

- **`POST /api/v1/sessions`** — body `{username, password}`; on a correct demo
  credential returns `201 {app_token, expires_at}`; on a bad credential returns
  `401` (no token leak, no timing oracle beyond bcrypt). The token is opaque,
  ≈187-bit, unique-indexed, with a TTL.
- **`GET /api/v1/jobs`** — with a valid bearer, returns the contractor's jobs
  (newest first) as `{jobs: [{id, address, status, created_at, ready summary…}]}`;
  with a missing/expired/invalid bearer returns **`401`** (never a `302` to the
  HTML login). Shape is stable and documented (the Swift `JobSummary` decodes it).
- **`GET /api/v1/jobs/:id`** — with a valid bearer, returns the job's `id`,
  `address`, current `status` (the pipeline status string), `last_error` when
  failed, and a report locator (`share_token` / report availability) when `ready`;
  `401` without a bearer; `404` for an unknown id.
- **`POST /api/v1/jobs`** (JSON) — with a valid bearer, body `{address}`, creates a
  job exactly as the web create does (enqueues the pipeline) and returns
  `201 {job_id, capture_token, capture_token_expires_at}` (the capture handoff the
  app carries into the capture flow). `401` without a bearer; `422` on a blank
  address.
- **`GET /api/v1/jobs/:id.json`** — accepts the **app bearer** (in addition to the
  existing web session) and returns the **identical** `JobExportSerializer` payload
  as `GET /r/:token.json`; `401` (not `302`) without a valid bearer; a ready job
  with no measurement returns `200` with `null` measurement (per the existing
  export contract), never a `500`.
- **No new auth model leakage:** these endpoints are the *contractor* surface; they
  never expose another deployment's data (single-tenant v1, but the bearer scopes
  to "the contractor", and job lookups are not cross-tenant-guessable beyond the v1
  single-user reality).
- **The `capture_token` path is untouched** — `POST /api/v1/capture-sessions/:job_id`
  still authenticates with the per-job `capture_token`, never the app bearer.

## Testing requirements

- **Request specs** for each endpoint: happy path with a valid bearer; `401` on
  missing/expired/garbage bearer (asserting the status is `401`, **not** `302`);
  `404` on unknown id; `422` on blank address; the `POST /api/v1/sessions`
  good-vs-bad-credential split.
- **Contract test:** `GET /api/v1/jobs/:id.json` (bearer) returns byte-identical
  serializer output to `GET /r/:token.json` for the same job (guards against a
  route-conditional serializer branch — the "JSON export identity" rule).
- **Token lifecycle:** an expired app token is rejected; a valid one authenticates;
  the token column has a DB unique index.
- **Security review lens:** brief with the auth-boundary + outbound-URL rules; the
  bearer is compared safely; no token value in logs/exception messages.

## Manual setup required

- None beyond the existing `DEMO_USERNAME` / `DEMO_PASSWORD_DIGEST` env (already
  provisioned by F-03). A DB migration adds the app-session-token table/columns.

## Build plan (planned 2026-05-31 · iteration `ios-full-app` · see `docs/BUILD-PLAN-ios-full-app.md`)

**Model tier:** Sonnet build → Opus review (all 6 dimensions) + skeptic on the auth/route
findings. Builds **concurrently with F-21**. The frozen contract this feature lands is
§1–§3 of the BUILD-PLAN.

### Architecture decisions
- **New `AppToken` model + `app_tokens` table** (not a column — no `User`/singleton home; multiple tokens; clean `current_user` migration seam). `has_secure_token :token, length: 32, on: :create` + **DB unique index** + non-null `expires_at`. **Plaintext lookup** (`AppToken.authenticate(raw)` → `find_by` + expiry reject), mirroring `Job.authenticate_capture_token` — NOT bcrypt.
- **`Api::V1::BaseController`** holds the shared bearer surface: `skip_before_action :require_demo_login`, `skip_forgery_protection`, `before_action :authenticate_app_token!` (renders `401`, never `302`), `bearer_token` (the `.presence` parse copied from `CaptureSessionsController`). `Api::V1::JobsController` inherits it.
- **`Api::V1::SessionsController#create`** (NOT under the bearer base — it mints the token) reuses the credential check via an extracted **`DemoCredential`** seam shared with the web `SessionsController`. Bad credential → `401` (API idiom).
- **Mobile create is `Api::V1::JobsController#create`** (bearer + skip-CSRF + clean 401), returning the **same** `{job_id, capture_token, capture_token_expires_at}` shape the web `format.json` returns — one iOS DTO. The web controller's `format.json` is left untouched.
- **`:id.json` keeps `JsonExportsController` verbatim** — only its **route** moves to the `.json` literal and its auth gains the bearer (`logged_in? || valid_app_bearer?`). No serializer change → export identity preserved.

### Route-collision resolution (LOAD-BEARING — see BUILD-PLAN §3)
The current `get "jobs/:id" => "json_exports#show", defaults: {format: :json}` matches BOTH
`:id` and `:id.json`. Resolve by declaring the **`.json` literal with `format: false`
BEFORE** the extensionless `:id` status route (the proven `r/:token.json` pattern). A
`route_to` spec guards both directions. Existing export specs must stay green.

### File-by-file
- [ ] `db/migrate/<ts>_create_app_tokens.rb` (via generator) — `app_tokens` (UUID PK): `token` string NOT NULL, `expires_at` datetime NOT NULL, timestamps; **unique index on `token`**.
- [ ] `app/models/app_token.rb` — `has_secure_token`; `TTL` const + `before_create` expiry; `self.authenticate(raw)`; `expired?`.
- [ ] `app/lib/demo_credential.rb` (PORO) — extract `valid_credentials?`/`bcrypt_matches?` from `SessionsController`.
- [ ] `app/controllers/sessions_controller.rb` (edit) — delegate to `DemoCredential` (behavior-preserving).
- [ ] `app/controllers/api/v1/base_controller.rb` — bearer auth surface (above).
- [ ] `app/controllers/api/v1/sessions_controller.rb` — `create` → `201 {app_token, expires_at}` | `401`.
- [ ] `app/controllers/api/v1/jobs_controller.rb` — `index`, `show` (status shape), `create`.
- [ ] `app/serializers/job_status_serializer.rb` (PORO) — the `JobSummary` + `JobStatusResponse` shapes.
- [ ] `app/controllers/api/v1/json_exports_controller.rb` (edit) — dual auth (`logged_in? || valid_app_bearer?`); serializer call unchanged.
- [ ] `config/routes.rb` (edit) — the api/v1 block in the BUILD-PLAN §3 order; delete the old `jobs/:id => json_exports#show` line.
- [ ] `config/initializers/filter_parameter_logging.rb` (edit) — add `:token, :app_token, :authorization` to `filter_parameters`.

### Ordered build steps (test-first)
- [ ] `spec/models/app_token_spec.rb` (RED): token-on-create; default TTL; `authenticate` valid/blank/unknown/expired; unique index raises `RecordNotUnique`. → migration + model (GREEN).
- [ ] `spec/lib/demo_credential_spec.rb` (good/bad/empty-env/malformed-digest). → extract `DemoCredential`; point `SessionsController` at it; existing `dev_login_spec` stays green.
- [ ] `spec/requests/api/v1/sessions_spec.rb` (RED): good cred → 201 + token; bad cred → 401, no token in body. → `Api::V1::SessionsController` + `BaseController` + route (GREEN).
- [ ] `spec/requests/api/v1/route_collision_spec.rb` (RED): `route_to` asserts `:id.json → json_exports#show`, `:id → jobs#show`. → reorder routes (GREEN).
- [ ] `spec/requests/api/v1/jobs_index_spec.rb` + `..._show_spec.rb` (RED): 200 shapes; newest-first; `last_error` only on failed; `share_token` on ready; 404 unknown; **401 not 302** on missing/expired/garbage bearer. → `index`/`show` + `JobStatusSerializer` (GREEN).
- [ ] `spec/requests/api/v1/jobs_create_spec.rb` (RED): 201 capture-handoff shape + `GeometryJob` enqueued; 422 blank address; 401 no bearer. → `create` (GREEN).
- [ ] `spec/requests/api/v1/json_export_bearer_spec.rb` (RED): bearer → 200; session still → 200; **contract test** `:id.json` body == `/r/:token.json` body; bad bearer (no session) → 401 not 302; ready-no-measurement → 200 null measurement. → move route + dual auth (GREEN).
- [ ] Add `:token,:app_token,:authorization` to `filter_parameters`; spec the bearer never appears in logs on a 401/500.
- [ ] Regression set green: `json_export`, `public_json_export`, `jobs`, `capture_sessions`, `dev_login`, `public_report` specs.
- [ ] `bundle exec rspec` full suite + `bin/rubocop` + `bin/brakeman`.

### Security lens (brief the reviewer)
Auth-boundary + outbound-URL rules. Plaintext-but-unique-indexed bearer lookup (187-bit, no
timing oracle worth defending) — mirror `authenticate_capture_token`. Credential path stays
`secure_compare` + bcrypt. 401-never-302 on the whole namespace. No token in
logs/exceptions (filter_parameters). `skip_forgery_protection` scoped to the API controllers.
Single-tenant scoping centralized so the future `current_user.jobs` change is one place.

### Open questions (mirrored in BUILD-PLAN): TTL (Q1), bad-cred 401 (Q2), share_token exposure (Q3), no revoke endpoint (Q5), refactor blast radius (Q6).

## Implementation notes (filled in by the building agent)

- Added `AppToken` as a UUID-backed table/model with `has_secure_token :token,
  length: 32`, a 30-day default expiry, plaintext lookup with expiry rejection,
  and a unique database index on `token`.
- Extracted `DemoCredential` into `app/lib` and moved the web login controller
  onto it unchanged from a user-facing behavior perspective. The API session
  controller uses the same seam and returns API-style `401` on bad credentials.
- Added `Api::V1::BaseController` for app bearer authentication. The mobile jobs
  controller inherits it; the capture-session upload remains on its existing
  per-job capture token path.
- Added `JobStatusSerializer` as a small PORO for the mobile `JobSummary` and
  `JobStatusResponse` shapes. Timestamps are emitted with `iso8601`; `share_token`
  is nullable and only comes from the job's report.
- Resolved the `/api/v1/jobs/:id` route collision by declaring the literal
  `/api/v1/jobs/:id.json` export route with `format: false` before the
  extensionless status route. A routing spec now guards both paths.
- Extended `Api::V1::JsonExportsController` auth to accept either the web session
  or a valid app bearer. The serializer invocation and payload construction were
  left unchanged; request coverage verifies byte-identical output to `/r/:token.json`.
- Added filtering for `app_token` and `authorization` alongside the existing token
  filters, including coverage for `HTTP_AUTHORIZATION`.
- Validation run: targeted F-20/API + nearby regressions passed with
  `env SKIP_REAL_SIDECAR=1 bundle exec rspec ...` (98 examples, 0 failures,
  1 existing pending capture-session Content-Length harness example). The local
  sandbox cannot reach Postgres without elevated execution, and the default
  real-sidecar suite hook needs elevated execution to reach local services.
- Static checks passed: `bin/rubocop` (196 files, no offenses) and
  `bundle exec brakeman --no-pager` (0 warnings). The `bin/brakeman` wrapper's
  latest-version check errored in this environment, so Brakeman was run directly
  through Bundler.
- Full suite was attempted with the real sidecar after first-run sidecar setup
  completed: `bundle exec rspec` ran 732 examples with 1 failure and 1 pending.
  The remaining failure is `spec/system/report_viewer_spec.rb:31`
  (`[data-controller="viewer"] *` not found), which is outside this API change.
