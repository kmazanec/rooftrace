# Feature: iOS live status (poll the pipeline)

**ID:** F-24 · **Roadmap piece:** F-24 · **Status:** Not started

## What this delivers (before → after)

**Before:** After creating a job the app has no way to show the pipeline running;
the web uses Turbo Streams the native client can't consume.

**After:** Opening a job shows a **live status timeline** — the pipeline stages
advancing (done ✓ / active / pending) over ~60–90 s — driven by polling, ending in
"View report" on success or a recoverable error on failure.

## How it fits the roadmap

The "watch the work happen" capability and the hub a job is viewed from. Depends on
F-21 + F-23; consumes F-20's `GET /api/v1/jobs/:id`. Polling, **not** ActionCable
(ADR-007 amendment).

## Requirements traced (from the PRD)

"Trigger the full flow … and watch it run." The honest-uncertainty stance: the
contractor sees *what* is happening and the method that produced the result.

## Dependencies (must exist before this starts)

- **F-21 iOS foundation + login** — design system, `APIClient`, the `JobStatus`
  lifecycle enum, nav.
- **F-23 iOS new measurement** — create pushes here with a `job_id`.
- **F-20 `GET /api/v1/jobs/:id`** — the polled status source (fakeable until it
  lands).

## Unblocks (what waits on this)

- **F-25 iOS capture relocated** — the "improve with a scan" entry is offered from
  here (carrying the `capture_token`).
- **F-26 iOS native report** — "View report" on `ready` pushes here.

## Contracts touched

- **iOS API client contract** (ADR-007 amendment) — *extends*: the polling loop
  over `Endpoint.job(id)`, decoding into the `JobStatus`/`Stage` enum (no
  stringly-typed status in the UI). Polling cadence: 2 s, exponential backoff to
  15 s on transient error, reset on success, cancel via `.task` on disappear, stop
  on terminal.
- **iOS native design system** (ADR-020) — *extends*: the vertical stage timeline
  (done/active-pulsing/pending), the determinate progress meter, and the
  failure-as-recoverable treatment, in the `cc-*` palette.
- **Honest uncertainty UX** (COMPANY.md / ADR-001) — the active stage carries a
  plain-language subcaption; the result's source/method is surfaced downstream.

## Acceptance criteria (product behavior)

- Opening a job **polls `GET /api/v1/jobs/:id`** (2 s; backoff to 15 s on transient
  error; reset on a good poll) and renders the stage timeline — `resolving_address`
  → `fetching_imagery` → `fetching_lidar` → `refining_outline` →
  `detecting_features` → `fitting_planes` — with completed stages checked, the
  active stage highlighted (+ a plain-language subcaption), and pending stages
  dimmed; a thin determinate meter reflects real stage-count progress.
- Polling **stops** on the terminal `ready`/`failed` states and **cancels** when
  the screen disappears (no leaked task).
- On **`ready`:** a "View report" primary button (pushes F-26) and, when capture is
  applicable, a secondary "Improve with a scan" entry (pushes F-25 with the
  `capture_token`).
- On **`failed`:** a recoverable error block (plain-language cause + "Try again" +
  "Back to jobs"), not an alarming red screen; orange-on-tint per the design
  system.
- The status string is decoded into the **`JobStatus` enum** at the boundary; the
  view `switch`es it exhaustively (a new backend stage is a compile error, not a
  silent blank).
- A `401` mid-poll returns the app to login (via `AuthStore`).

## Testing requirements

- **Unit tests** (fake `APIClient`): the polling loop advances
  `processing → processing → ready` and stops; honors cancellation; backs off on a
  thrown transient error and resets on success; maps each status to the right
  stage UI; `failed` surfaces the error; `401` triggers re-auth.
- **Manual:** the live cadence + animation against a real running pipeline is in
  the manual test plan (the timing is observed, the logic is unit-tested with an
  injected clock per the `ClockProviding` pattern).

## Manual setup required

- None beyond F-21.

## Build plan (planned 2026-05-31 · iteration `ios-full-app` · see `docs/BUILD-PLAN-ios-full-app.md`)

**Model tier:** Sonnet build → Opus review. Depends on F-21 + F-23; ∥ F-26. Built against
fakes. **Owns** the poll-loop contract + `SegmentedProgress` (BUILD-PLAN §8–§9).

### Architecture decisions
- `StatusPollViewModel` runs ONE structured poll loop started in `.task(id: jobID)` and torn down by `.task` cancellation on disappear — no manual `Task` stored on the VM.
- Cadence + backoff via an injected `ClockProviding` (reuse F-15's pattern) so timing is unit-tested with a fake clock.
- The view `switch`es `JobStatus` exhaustively (no `default`); the timeline renders the 6 `Stage.allCases` in order, done/active/pending by index; the determinate meter = `(activeIndex+1)/6`.
- Backoff is per-loop state **reset on a successful decode**, orthogonal to terminal-stop.

### Adds
- View-model `StatusPollViewModel` (poll loop 2s→backoff 15s, `currentStatus: JobStatus`, terminal handling); view `JobStatusView` (vertical stage timeline; determinate meter; ready→"View report" + "Improve with a scan"; failed→recoverable block + "Try again"/"Back to jobs").
- Component **`SegmentedProgress`/`ProgressDots`** (owned here; **F-25 reuses** with a count param). Consumes **`StatusIndicator`** from F-22. Active-stage pulse honors reduced-motion.
- Consumes F-21's `job(id:) -> JobStatusResponse`; reuses F-23's stashed `CaptureHandoff` for the scan entry.

### Contrarian failure modes
- Polling task leak: die on disappear via `.task` (auto-cancel) + `try Task.checkCancellation()` each iteration; never a detached `Task {}`.
- Pushing `.report` keeps the status view in the back-stack (not disappeared) — the loop must still stop on `ready` (terminal) so it isn't polling behind the report.
- Backoff reset: a transient throw escalates 2→4→8→15; the next good poll resets to 2 (test the reset, not just escalation).
- 401 mid-poll → `handleUnauthorized` (clears+flips→stack unmounts→loop cancels); distinguish 401 (re-auth, stop) from transient (backoff, continue).
- Terminal stop is total — **both** `ready` and `failed` stop the loop.
- `Task.sleep` throws on cancel — let it propagate to exit, don't swallow.
- `failed` is recoverable (orange-on-tint), not an alarming red screen; plain-language cause from the reason.
- "Improve with a scan" only when capture applicable + a valid (non-expired) `CaptureHandoff`.

### Ordered build steps (test-first)
- [ ] `StatusPollViewModel` tests (fake clock + FakeAPIClient): `processing→processing→ready` advances then stops; cancellation stops; transient throw→backoff escalates; good poll→resets; `failed` surfaces reason + stops; 401→`handleUnauthorized`.
- [ ] Implement the poll loop (interval state, backoff, terminal-stop, cancellation checks).
- [ ] Map `Stage.allCases`→timeline rows + unit test each status→correct timeline.
- [ ] Build `SegmentedProgress`/`ProgressDots` + the vertical timeline (reduced-motion pulse).
- [ ] Build `JobStatusView` (timeline + meter + ready actions + failed recoverable block).
- [ ] Wire ready→`.report`, scan→`.capture(handoff)`, failed→try-again/back; 401→re-auth.
- [ ] Confirm `.task(id:)` lifetime + disappear teardown.

### Test list
- **Unit (fake clock + FakeAPIClient):** loop advance+stop; cancellation; backoff escalate+reset; status→timeline mapping (all stages); failed surfaces reason; 401 re-auth.
- **Manual/device:** live cadence + active-stage pulse vs the real running pipeline; reduced-motion.

### Contract touchpoints frozen
Owns the poll-loop contract (2s→15s, reset-on-success, cancel-on-disappear, stop-on-terminal)
+ `SegmentedProgress`; the `.capture(CaptureHandoff)` consumption site (F-23's handoff →
F-25's entry); `ready → .report` push for F-26.

## Implementation notes (filled in by the building agent)

> Owned by the builder. Starts empty.
