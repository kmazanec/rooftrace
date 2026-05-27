# ADR-016: V1 auth = single dev login on submit + opaque public-share tokens on reports

**Status:** Accepted · **Date:** 2026-05-27 · **Stretch:** no
**Supersedes:** none · **Superseded by:** none

## Context

The brief implies external sharing ("shareable links or PDFs"). The
project has three distinct auth surfaces:

1. **iOS app → backend** (ADR-007): the iOS capture session needs to
   authenticate to upload its multipart bundle. Scoped to a single job.
2. **Web submitter (the contractor)** — types in an address and starts a
   job. Should be gated so the demo deployment isn't an open address-
   lookup proxy.
3. **Public report viewer** — receives a share URL from the
   contractor; views the read-only report; downloads the PDF/JSON.
   Should *not* require authentication for the recipient.

The 4-day budget rules out a real user-account system (signup, email
verification, password reset, account management UI). And there's no
production benefit to building one — at this stage the product has one
user (the contractor) per deployment and infinity recipients (anyone
with a share link).

The shape that fits is: **one shared dev login on the submit
surface; opaque random tokens scoped to each shared report.** This is
the same auth shape Linear, Loom, and Figma use for "share this with
someone outside your org" — and it's the same shape CompanyCam's own
public project-share links already use.

## Options considered

**A. Single dev login (HTTP basic or a simple session cookie) on
submit pages + opaque public-share tokens on report URLs.** No user
records, no email infrastructure, no password reset. Submit gate is
an env-configured username + password. Each generated report has a
random 32-char token (`/r/<token>`); knowing the token grants
read-only access.
*Tradeoff:* shippable in an hour; matches the actual product surface;
zero user-management code.

**B. Magic-link email auth + share tokens.** Same share-token
mechanism for recipients; submitters sign in via an email-link flow.
*Tradeoff:* one more moving piece (email provider — Postmark / Resend);
real per-user records in the DB; reasonable if user identity matters
for the demo, but it doesn't.

**C. Full Rails session auth.** Signup, login, password reset, account
mgmt.
*Tradeoff:* days of v1 scope spent on a problem nobody is grading.

**D. No auth at all on submit; just share tokens on reports.** Open
the submit surface.
*Tradeoff:* the demo deployment becomes a free address-lookup +
LiDAR-pipeline service for anyone who finds the URL; cost + abuse
concerns.

**E. iOS-to-backend auth via the same share token.** Reuse the token
machinery.
*Tradeoff:* mostly fine, but the iOS app is the contractor's tool,
not the recipient's, so it should authenticate as a *submitter*, not
a recipient. Token granularity matters.

## Decision

**A. Single dev login on submit; opaque per-report public-share tokens
on reports; short-lived job-scoped session tokens for iOS uploads.**

Specifically:

- **Submit surface** (`/`, `/jobs/new`) sits behind a single login
  configured via two env vars (`DEMO_USERNAME`, `DEMO_PASSWORD`).
  Login is a Rails-native session cookie (Devise not needed — a
  controller filter + `bcrypt`-hashed password env var).
- **Report viewer** at `/r/<token>` accepts any 32-char base32 token
  that matches a `Report#share_token` row; granted read-only access
  to that report's HTML viewer, PDF download, and JSON export.
- **iOS app** receives a short-lived (24-hour) session token at job
  creation time, scoped to a single `job_id`. POSTs to
  `/api/v1/capture-sessions/:job_id` are authenticated by that token
  in an `Authorization: Bearer ...` header.
- **No user records, no signup, no email infra.**

## Rationale

This is the minimum auth surface that satisfies the project's real
requirements:

- The recipient experience (a homeowner clicking a contractor's link)
  is exactly right: open the URL, see the report, no signup. This is
  the share-link UX CompanyCam already trains its users in; it's the
  right mental model for the demo.
- The submitter experience prevents the demo deployment from being an
  open proxy without the cost of building user management for a
  feature that doesn't exist yet.
- The iOS auth model is appropriately narrow — a token scoped to one
  job means the app can never accidentally read or modify another
  contractor's data.

The CTO defense is honest scope: *"V1 has no user-management problem to
solve, so it has no user-management code. The shape grows naturally
into accounts when there are actual customers — replace the dev login
with a Rails session-based User model; share tokens stay as-is."*

## Tradeoffs & risks

- **Single shared submitter credential** means there's no audit trail
  of which person submitted which job. Mitigation: acceptable for v1;
  the demo is single-user; production rollout adds real accounts.
- **Share tokens are URL-bearer credentials.** Anyone with the URL has
  access. Mitigation: tokens are 32 base32 chars (≈160 bits of
  entropy) — uncrackable; document the model in the share-link UI
  ("anyone with this link can view"); optional token-revoke surface
  for v1.5.
- **iOS token replay**, if intercepted. Mitigation: tokens are
  24-hour TTL and job-scoped; HTTPS-only; for v1 this is acceptable;
  v2 adds device-pinning.
- **No password reset.** Mitigation: env-var rotation is the
  "password reset" for v1; users (just Keith for the demo) know to
  restart on rotation.
- **Migration path to real accounts** is the path the surrounding
  Rails stack already supports. Mitigation: documented as part of
  the writeup.

## Consequences for the build

- **`ApplicationController`** has a `before_action :require_demo_login`
  that checks `session[:demo_logged_in]`; redirects to `/login` if not.
- **`LoginController`** has `new` (render the login form) and `create`
  (compare submitted password to `bcrypt`-digested `DEMO_PASSWORD`
  env; set session flag). One page, two actions.
- **`Report` model** has a `share_token` column (32-char base32),
  generated on `before_create` via `SecureRandom.base32(32)`,
  unique-indexed in Postgres.
- **`ReportsController#show_public`** at `/r/:token` finds the report
  by `share_token` and renders read-only; no login filter; sets
  `X-Robots-Tag: noindex`.
- **iOS auth:**
  - `Job` model has a `capture_token` column (similar shape), set on
    create with a 24-hour TTL (`capture_token_expires_at`).
  - `Api::V1::CaptureSessionsController` extracts the bearer token
    from the request header, looks up `Job.find_by(capture_token:
    ...)` with expiry check, and proceeds.
  - The job creation response returns
    `{job_id, capture_token, capture_token_expires_at}` to the iOS
    client.
- **Env vars:** `DEMO_USERNAME`, `DEMO_PASSWORD`,
  `DEMO_PASSWORD_DIGEST` (`bcrypt`-digested at deploy time, not
  stored plain).
- **No user records in Postgres v1**. The `users` table will be added
  later, and these decisions will gracefully evolve into a User
  model.
- **Migration path documented:** swap dev-login for a User model
  (Devise or rolled-by-hand); share tokens unchanged; iOS auth model
  unchanged.
