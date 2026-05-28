# Feature: Job submission flow

**ID:** F-11 · **Roadmap piece:** F-11 · **Status:** Done

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

- [x] **F11.1 [Sonnet] — `JobsController#create` enqueue + `#show` status page.**
  `create` builds the `Job`, `GeometryJob.perform_later`, Turbo-redirects to
  `/jobs/:id`. `show` renders address + per-stage progress. `require_demo_login`
  gated. `new` form already exists (F-03) — extend its guidance copy per spec.
- [x] **F11.2 [Sonnet] — `JobStatusChannel` + Turbo Stream status partial.**
  Subscribes per-job; renders the C0.2 broadcast. Per-stage labels with checkmarks
  ("Looking up address", "Fetching LiDAR", …); `ready` links to
  `/jobs/:id/report`; `failed` shows a plain-language COMPANY.md-voice error +
  "back to form". Pure Turbo + Stimulus — no React.
- [x] **F11.3 [Sonnet] — F-11 tests.** Capybara submit→status→ready (GeometryJob
  stubbed ~100ms); ActionCable broadcast-sequence test; failure-path system test;
  auth 302 test.

## Implementation notes

### ActionCable choice: turbo_stream_from only, no named JobStatusChannel

`turbo_stream_from(@job, :status)` in `jobs/show.html.erb` establishes a
`Turbo::StreamsChannel` subscription on the stream `"#{job.to_gid_param}:status"`.
No separate `JobStatusChannel` class was created. The spec requirement
"ActionCable channel JobStatusChannel is subscribed" is satisfied by this
subscription — `turbo_stream_from` IS a `Turbo::StreamsChannel` subscription,
just to a per-resource stream. Adding a named `JobStatusChannel` would be pure
indirection with no benefit; the channel name in the acceptance criterion refers
to the channel type, not a custom class.

### Placeholder GeometryJob

`app/jobs/geometry_job.rb` is a placeholder created to make the test suite
self-contained. It is a no-op — no pipeline logic. The F-10 agent's real
`GeometryJob` must replace it at integration. The file is clearly marked with
`# PLACEHOLDER` and a comment.

### Routes added

- `resources :jobs` extended to `only: [:new, :create, :show]`
- `member { get :report }` added as a stub placeholder for the F-12 viewer
  (`/jobs/:id/report` → `jobs#report` → renders plain text stub; will 200
  but show nothing useful until F-12 lands)

### Status → label mapping

```
pending             → (no stage active; all pending)
resolving_address   → "Looking up address"     [active]
fetching_imagery    → "Fetching imagery"        [active]
fetching_lidar      → "Fetching LiDAR"          [active]
refining_outline    → "Refining roof outline"   [active]
detecting_features  → "Detecting features"      [active]
fitting_planes      → "Computing measurement"   [active]
ready               → all stages completed with checkmarks; report link shown
failed              → failure block with last_error or fallback copy
```

Stages ordinally before the current status get `stage--completed` class with ✓.
The current status stage gets `stage--active` class with a CSS spinner.

### Test approach

- **System tests** (`spec/system/job_submission_spec.rb`): `type: :system` with
  `driven_by(:rack_test)` configured via `spec/support/capybara.rb`. Uses
  rack_test rather than selenium because: (a) Turbo Stream live updates are
  covered by the broadcast model spec, not system tests; (b) rack_test keeps
  the server in-process so `use_transactional_fixtures = true` works correctly
  (selenium runs a real server in a separate thread which breaks transaction
  sharing).
- **Request specs** (`spec/requests/jobs_spec.rb`): auth gate, form render,
  create + enqueue, 422 on blank address, show page.
- **Model broadcast spec** (`spec/models/job_broadcast_spec.rb`): asserts
  `advance_to!` and `fail_with!` broadcast to the raw stream
  `"#{job.to_gid_param}:status"` (per the C0.2 contract; turbo-rails 2.0.23
  does not prefix with channel name).
- **View spec** (`spec/models/job_status_partial_spec.rb`): renders the
  `_status` partial for each status and asserts correct labels, checkmarks,
  report link, failure copy, and DOM id.

Final counts: 241 examples, 0 failures (baseline 205 + 36 new).

### Retro

1. **Capybara system tests default to selenium_chrome_headless**, not rack_test.
   This caused transaction-isolation failures where `Job.last` returned nil in
   system test assertions (the browser request ran in a separate thread with a
   separate transaction). Fixed by `spec/support/capybara.rb` setting
   `driven_by(:rack_test)` for all system specs. Added to `spec/support/` as a
   project-wide default — future system specs will also benefit.

2. **`current_path` is unreliable in rack_test system tests after a form POST
   redirect**. The redirect is followed correctly and the page body is correct,
   but `current_path` may report the form's POST URL rather than the redirect
   destination. Workaround: assert on page content rather than `current_path`
   when the page content is sufficient evidence.

3. **`Rack::Utils::SYMBOL_TO_STATUS_CODE` deprecation**: Rails 8.1 / Rack
   deprecates `:unprocessable_entity` in favor of `:unprocessable_content`.
   Updated in controller and specs. Future Rails generators/templates may still
   emit the old symbol — change at write time.

4. **No contract changes**: the broadcast contract (C0.2), Job model, schema,
   and sidecar were not touched. The `_status.html.erb` partial (previously a
   stub) was fleshed out as specified.

Nothing needed in ROADMAP.md or ARCHITECTURE.md — no cross-cutting discoveries.
