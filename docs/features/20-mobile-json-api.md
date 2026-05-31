# Feature: Mobile JSON API (sessions + jobs index + job status + JSON create)

**ID:** F-20 · **Roadmap piece:** F-20 · **Status:** Not started

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

## Implementation notes (filled in by the building agent)

> Owned by the builder, not the planner. Starts empty. Record the chosen token
> table/model shape, the `before_action` seam, any controller-namespace decisions,
> and propagate cross-cutting discoveries to ROADMAP.md / the ADRs.
