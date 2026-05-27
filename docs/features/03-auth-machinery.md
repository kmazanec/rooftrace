# Feature: Auth machinery (dev login + share tokens + iOS capture tokens)

**ID:** F-03 · **Roadmap piece:** F-03 · **Status:** Not started

## Description

Implements the three auth surfaces from
[ADR-016](../adrs/ADR-016-auth-dev-login-plus-share-tokens.md):

1. **Single dev login** on submit pages (`/jobs/new` and any
   contractor-facing routes) gated by a `before_action`.
2. **Opaque public-share tokens** on report URLs (`/r/:token`) granting
   read-only access without authentication.
3. **Short-lived bearer tokens** for the iOS app's capture upload,
   scoped to a single `job_id` with a 24-hour TTL.

Why it exists: gates the deployed system so it isn't an open
address-lookup proxy, and provides the auth primitives every app-layer
feature and the iOS app need. No user records, no signup flow — v1 is
deliberately minimal per the ADR.

## How it fits the roadmap

Wave 1 — parallel with F-02 (contract) and F-04 (brand). Unblocks the
entire app-layer track (F-11 submission, F-12 viewer) and the iOS
track (F-15, F-16). One node off the critical path.

## Dependencies (must exist before this starts)

- **F-01 Walking skeleton** — needs the deployed Rails app to add
  controllers/filters into.

## Unblocks (what waits on this)

- **F-11 Job submission flow** — submit routes need
  `require_demo_login`.
- **F-12 Web report viewer** — public-share route needs token
  resolution.
- **F-15 iOS capture app** — needs `capture_token` to authenticate
  uploads.
- **F-16 iOS capture ingest** — validates the bearer token on
  incoming POSTs.

## Acceptance criteria

- **Dev login:**
  - Unauthenticated GET to `/jobs/new` returns 302 redirecting to
    `/login`.
  - POST to `/login` with the correct username + password (matched
    against the env vars `DEMO_USERNAME` / `DEMO_PASSWORD_DIGEST`,
    the latter being a bcrypt digest) sets a session cookie and
    302-redirects to the original destination.
  - POST with wrong credentials returns 200 with an error message
    (not 401 — keep the login form discoverable for the demo).
  - Logged-in user can hit `/logout` which clears the session and
    redirects to `/login`.
- **Public share tokens:**
  - `Report` model has a `share_token` column (32-char base32),
    generated on `before_create` with `SecureRandom.base32(32)`,
    unique-indexed.
  - GET `/r/:token` finds the report by `share_token`; renders a
    minimal read-only stub view (real viewer comes in F-12); sets
    `X-Robots-Tag: noindex`.
  - GET `/r/:bad_token` returns 404, not 302 to login.
- **iOS capture tokens:**
  - `Job` model has `capture_token` (similar 32-char base32) and
    `capture_token_expires_at` (DateTime, defaults to 24h after
    job creation).
  - When a job is created, the JSON response includes `{job_id,
    capture_token, capture_token_expires_at}`.
  - POST `/api/v1/capture-sessions/:job_id` requires
    `Authorization: Bearer <capture_token>`; rejects (401) on
    missing/wrong/expired token; accepts (200 stub for now — real
    ingest is F-16) on valid token.
- **No user records in the database for v1.** The `users` table is
  intentionally absent; the dev login is a session-only construct.

## Testing requirements

- **Request specs** for all three auth surfaces covering the happy
  path and the rejection cases listed above.
- **Token-rotation test:** rotating `DEMO_PASSWORD_DIGEST` and
  redeploying causes existing sessions to lose access on next
  request (acceptable trade-off for v1; documented).
- **Token-expiry test:** an iOS request with a `capture_token` past
  its `capture_token_expires_at` returns 401 with a clear error.
- **Token-entropy test:** unit-tests on token generation confirm
  base32 length and uniqueness within a fixture batch of 10k.

## Manual setup required

- **Generate and set `DEMO_PASSWORD_DIGEST` env var** for the
  deployed environment: `bcrypt` digest of the chosen password,
  injected via Kamal secrets.
- **Choose and set `DEMO_USERNAME` env var.**
- **Document the dev credentials** in a private note for the demo
  presenter — they're not stored elsewhere.

## Implementation notes (filled in by the building agent)

> The agent implementing this feature records its implementation
> decisions and rationale here as it builds — chosen libraries/patterns
> within the architecture's constraints, trade-offs made, deviations
> from assumptions and why, and anything the next agent or the
> integrator needs to know. This section starts empty and is owned by
> the builder, not the planner. Cross-cutting discoveries that affect
> other features must also be propagated to ROADMAP.md or the
> architecture doc, not just left here.
