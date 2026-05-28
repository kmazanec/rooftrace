# Feature: Job submission flow

**ID:** F-11 · **Roadmap piece:** F-11 · **Status:** Not started

## Description

The contractor-facing surface for kicking off a measurement: an
address-entry form, Solid Queue enqueue of the `GeometryJob`
(implemented by F-10), and real-time status updates over ActionCable
via Turbo Streams. Per
[ADR-013](../adrs/ADR-013-web-stack-hotwire-react-island.md), this is
pure Hotwire — no React — because the UX is form + status, not
interactive viz.

The status surface needs to be honest: the COMPANY.md design contract
says crews respect tools that *show their work*, not tools that spin
silently for two minutes.

## How it fits the roadmap

Wave 2 / Wave 3 — can be built in parallel with the pipeline track;
ready to wire to F-10 the moment the orchestrator lands. Off the
critical path. Unblocks the web viewer (F-12).

## Dependencies (must exist before this starts)

- **F-01 Walking skeleton** — Rails + ActionCable working.
- **F-03 Auth machinery** — submit routes gated by
  `require_demo_login`.

## Unblocks (what waits on this)

- **F-12 Web report viewer** — navigation flows from submit →
  status → viewer.

(F-11 does *not* unblock F-10. F-10 can run standalone via a console
invocation; F-11 provides its production trigger surface but is not
a hard prerequisite for F-10's acceptance.)

## Acceptance criteria

- **GET `/jobs/new`** renders a form with a single address text
  input, submit button, and any helpful inline guidance (e.g., "Try
  a US residential address; supports street + city/state +
  optional ZIP"); gated by `require_demo_login`.
- **POST `/jobs`** creates a `Job` record, enqueues the GeometryJob
  via Solid Queue, returns Turbo-Stream-redirecting the user to
  `/jobs/:id` (the status page).
- **GET `/jobs/:id`** renders the status page: address, current
  status, progress indicators per pipeline stage. When status is
  `ready`, the page links/redirects to the report viewer
  (`/jobs/:id/report`, F-12).
- **ActionCable channel** `JobStatusChannel` is subscribed by the
  status page; broadcasts Turbo Stream replacements as the
  GeometryJob progresses through its named statuses (per F-10's
  status enum).
- **The status surface shows the work being done:** at minimum
  per-stage labels ("Looking up address", "Fetching LiDAR",
  "Refining roof outline", "Detecting features", "Computing
  measurement") with a checkmark when each completes; failure of
  any stage shows an actionable error.
- **Failure UX:** if the GeometryJob fails (e.g., address not
  geocodable, no building footprint found), the status page shows
  a plain-language error consistent with the COMPANY.md voice
  ("We couldn't find a building at this address — please check the
  spelling and try again") with a "back to form" link.
- **Concurrency:** multiple users (or the demo + another tab)
  submitting different addresses don't interfere; each gets its
  own job/channel.
- **No JS framework on these pages** — pure Turbo + Stimulus. The
  React island is reserved for the report viewer (F-12).

## Testing requirements

- **System test (Capybara):** full submit → status → "ready"
  redirect flow on a fixture address with the GeometryJob stubbed
  to complete in 100ms.
- **ActionCable test:** asserts the channel broadcasts the
  expected sequence of Turbo Streams for a happy-path run.
- **Failure-path system test:** submits an unresolvable address;
  asserts the error message and "back to form" UX.
- **Auth test:** unauthenticated GET/POST returns 302 to
  `/login`.

## Manual setup required

- **None** — pure Rails feature; depends on F-01 and F-03
  groundwork.

## Build plan (approved 2026-05-28; batch with F-10)

Built in the F-10+F-11 unified batch on `feat/iter3-orchestrator-and-submission`.
Tier: **Sonnet** end-to-end workstream (pure Hotwire, builds against the Job
status/broadcast seam Opus locks in F-10's Phase 0); Opus briefs, verifies,
integrates. Depends only on the C0.2 status enum + broadcast contract.

- [ ] **F11.1 [Sonnet] — `JobsController#create` enqueue + `#show` status page.**
  `create` builds the `Job`, `GeometryJob.perform_later`, Turbo-redirects to
  `/jobs/:id`. `show` renders address + per-stage progress. `require_demo_login`
  gated. `new` form already exists (F-03) — extend its guidance copy per spec.
- [ ] **F11.2 [Sonnet] — `JobStatusChannel` + Turbo Stream status partial.**
  Subscribes per-job; renders the C0.2 broadcast. Per-stage labels with checkmarks
  ("Looking up address", "Fetching LiDAR", …); `ready` links to
  `/jobs/:id/report`; `failed` shows a plain-language COMPANY.md-voice error +
  "back to form". Pure Turbo + Stimulus — no React.
- [ ] **F11.3 [Sonnet] — F-11 tests.** Capybara submit→status→ready (GeometryJob
  stubbed ~100ms); ActionCable broadcast-sequence test; failure-path system test;
  auth 302 test.

## Implementation notes (filled in by the building agent)

> The agent implementing this feature records its implementation
> decisions and rationale here as it builds — chosen libraries/patterns
> within the architecture's constraints, trade-offs made, deviations
> from assumptions and why, and anything the next agent or the
> integrator needs to know. This section starts empty and is owned by
> the builder, not the planner. Cross-cutting discoveries that affect
> other features must also be propagated to ROADMAP.md or the
> architecture doc, not just left here.
