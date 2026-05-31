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

## Implementation notes (filled in by the building agent)

> Owned by the builder. Starts empty.
