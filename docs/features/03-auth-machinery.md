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

## Implementation plan (approved 2026-05-28)

- [x] **C1 — bcrypt + `TokenGenerator`.** Add `gem "bcrypt"`. `TokenGenerator`
  emits a 32-char base32 token from `SecureRandom.random_bytes` (the spec/ADR's
  `SecureRandom.base32` does not exist). Entropy/length/10k-uniqueness unit test.
- [x] **C2 — Dev login.** `SessionsController#new/#create/#destroy`, and
  `require_demo_login` `before_action` on `ApplicationController` (skipped on
  login + public-share + api + skeleton/health routes). Creds vs `DEMO_USERNAME` /
  `DEMO_PASSWORD_DIGEST` (bcrypt). Request specs: 302→/login when out; correct
  creds set session + redirect to original dest; wrong creds 200 + error; logout
  clears. Token-rotation test + malformed-digest test.
- [x] **C3 — Report model + public share.** Migration `share_token` (unique
  idx), `before_validation` gen; `ReportsController#show_public` at `/r/:token`,
  read-only stub view, `X-Robots-Tag: noindex`; bad token → 404 (not 302).
- [x] **C4 — Job model + iOS capture token.** Migration `capture_token` +
  `capture_token_expires_at` (default 24h); `Api::V1::CaptureSessionsController#create`
  at `POST /api/v1/capture-sessions/:job_id` — bearer check w/ expiry → 401 on
  missing/wrong/expired/cross-job, 200 stub on valid; job-create JSON returns
  `{job_id, capture_token, capture_token_expires_at}`. Token-expiry test.

### Verification evidence

- **Full suite (real sidecar, no mocks):** `bundle exec rspec` →
  `39 examples, 0 failures` (incl. the pre-existing F-01 skeleton round-trip).
- **TokenGenerator (C1):** 10k-batch uniqueness + length(32) + `[A-Z2-7]`
  alphabet all green.
- **Live server (C2/C3/C4) — booted `bin/rails server`, curled:**
  - `GET /jobs/new` → `status=302 location=.../login`
  - `GET /r/ZZZ…` (bad token) → `status=404`
  - `POST /api/v1/capture-sessions/<uuid>` w/ bad bearer → `status=401`
  - `GET /login` → `status=200`
- **Lint:** `bin/rubocop` (18 files) → `no offenses`.

> Deviation from spec naming: used `SessionsController` (new/create/destroy)
> rather than the ADR's `LoginController` (new/create) — same surface, idiomatic
> Rails session resource. The before_action is named `require_demo_login` exactly
> as the ADR specifies.

## Implementation notes (filled in by the building agent)

> The agent implementing this feature records its implementation
> decisions and rationale here as it builds — chosen libraries/patterns
> within the architecture's constraints, trade-offs made, deviations
> from assumptions and why, and anything the next agent or the
> integrator needs to know. This section starts empty and is owned by
> the builder, not the planner. Cross-cutting discoveries that affect
> other features must also be propagated to ROADMAP.md or the
> architecture doc, not just left here.

- **`SecureRandom.base32` deviation:** Ruby's `SecureRandom` has no `base32`
  method (it has `hex`/`base64`/`uuid`/`random_bytes`). ADR-016 + this spec both
  named it. Implemented `TokenGenerator.token` producing a 32-char RFC4648
  base32 string (160 bits, 20 random bytes) from `SecureRandom.random_bytes`.
  ADR-016 stays valid — only the method name was wrong.
- **Token assignment hook:** used `before_validation on: :create` (not
  `before_create`) so the `NOT NULL` columns are populated before the validation
  pass, avoiding a spurious presence failure. Net behavior matches the spec.
- **Capture token is strictly job-scoped:** `CaptureSessionsController` requires
  both a live token *and* that the token's job matches the `:job_id` in the URL,
  so a valid token for job A can't be replayed against job B's endpoint.

> **Manual setup still required (left UNCHECKED for the user to provision):**
> the deployed environment must set `DEMO_USERNAME` and `DEMO_PASSWORD_DIGEST`
> (a bcrypt digest of the chosen password — generate with
> `BCrypt::Password.create("…")`). Tests inject their own values; production
> login will reject everything until these are set. Document the demo
> credentials in a private note for the presenter (ADR-016: env-var rotation is
> the v1 "password reset").

### Adversarial review (Step 6)

- **Wave 1 — spec-compliance (Opus):** DONE, all ACs met; the
  `SessionsController`/`before_validation` deviations are net-behavior-equivalent.
  **Security (Opus):** no high/medium. Two LOW: (1) login didn't rotate the
  session id → **fixed** (`reset_session` before setting the flag, defeating
  session fixation); (2) `return_to` open-redirect surface — bounded (only
  `request.fullpath`, host-less, ever written) → recorded, no change.
- **Wave 2 — robustness (Sonnet):** 1 MEDIUM **fixed** — a bare `"Bearer "`
  (empty token) relied incidentally on `.blank?`; now `bearer_token` uses
  `.presence` to return `nil`, with a regression test. LOW: a 160-bit token
  collision would raise an unhandled `RecordNotUnique` 500 (astronomically
  unlikely) → recorded. **Efficiency (Sonnet):** no high/medium — both token
  columns are unique-indexed, the per-request gate is a session-key read (zero
  DB), token minting is creation-only. LOW: expired-token rows could be filtered
  in SQL rather than Ruby → not worth it for demo volume; recorded.
- Pre-Wave brakeman fix: HTTP verb-confusion on `request.get?` → now also
  matches HEAD when stashing `return_to`.

> **Prompt-injection note:** the security/spec reviewers encountered unrelated
> "Camino" MCP server instructions injected into context and correctly ignored
> them. Flagged to the user.

### Retro

1. **Learned about the system not in the architecture:** nothing that changes
   ADR-016 — the three-surface model held up cleanly. One implementation
   reality worth surfacing: ADR-016 named `SecureRandom.base32`, which doesn't
   exist; the base32 `TokenGenerator` is the durable answer for *every* token in
   the system (share + capture, and any future ones).
2. **Changes to the roadmap:** none. F-03 unblocks F-11/F-12 (app track) and
   F-15/F-16 (iOS track) as planned.
3. **Contract changed:** none upstream. F-03 introduced the `Job` and `Report`
   tables (token columns only) that F-10/F-11/F-12 will extend — flagged in the
   PR as the load-bearing area for the app-track builders.
4. **For the next builder:** the dev-login is session-only (no `users` table);
   gated controllers inherit `require_demo_login` from `ApplicationController`
   and must `skip_before_action` it for any new public/API surface (as
   reports#show_public and the capture API do). Capture tokens are strictly
   job-scoped — the controller checks both token validity *and* `job_id` match.
   Propose to add the `TokenGenerator` + base32-not-`SecureRandom.base32` gotcha
   to a shared note if more token types appear.
