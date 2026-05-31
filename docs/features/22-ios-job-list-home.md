# Feature: iOS job list / home

**ID:** F-22 · **Roadmap piece:** F-22 · **Status:** Not started

## What this delivers (before → after)

**Before:** After login the app lands on an empty home; there is no way to see the
contractor's jobs natively (the web has no job-list either — this is net-new).

**After:** The home is a **list of the contractor's jobs** — each row showing the
address, a status pill, the roof-area number (mono) for ready jobs, and a relative
date — with pull-to-refresh, a confident empty state, and a pinned
"＋ New measurement" CTA. Tapping a job opens its status or report.

## How it fits the roadmap

The post-login identity screen. Depends on F-21 (foundation) and consumes F-20's
`GET /api/v1/jobs`. Builds against a fake `APIClient` first.

## Requirements traced (from the PRD)

The native client's home surface; makes the app feel like an app (a logbook of
jobs) rather than a single-flow tool.

## Dependencies (must exist before this starts)

- **F-21 iOS foundation + login** — design system, `APIClient`, `AuthStore`, nav
  shell, `JobSummary` DTO + `JobStatus` enum.
- **F-20 `GET /api/v1/jobs`** — the data source (fakeable until it lands).

## Unblocks (what waits on this)

- **F-23 iOS new measurement** — reached from the home's "＋ New measurement" CTA.
- **F-24 iOS live status** — reached by tapping a non-ready job.

## Contracts touched

- **iOS API client contract** (ADR-007 amendment) — *extends*: adds the
  `Endpoint.jobs` call + the `JobSummary` decode.
- **iOS native design system** (ADR-020) — *extends*: introduces `JobRow`,
  `StatusIndicator` (the multi-status pill), the home empty state, and the pinned
  CTA, all in the `cc-*` palette.
- **Honest uncertainty UX** (COMPANY.md / ADR-001) — status + the ready-job area
  number are surfaced honestly; status differentiates by glyph+label, not color
  alone.

## Acceptance criteria (product behavior)

- After login, the home fetches `GET /api/v1/jobs` and renders the contractor's
  jobs newest-first; each row shows the address, a **status pill** (glyph + label,
  not a stoplight color), the **total area in SF Mono** for ready jobs, and a
  relative date; the whole row is a ≥ 44 pt tap target.
- **Pull-to-refresh** re-fetches; a transient fetch error shows an inline
  "couldn't load — try again" affordance while keeping any already-loaded rows.
- **Empty state** (no jobs): a guiding state (roof-peak glyph + a short line +
  a "Start your first measurement" primary button), not a blank list.
- **Loading state:** skeleton rows on first fetch (not a bare centered spinner),
  honoring reduced-motion.
- The **"＋ New measurement" CTA** is pinned and reachable one-handed; it opens the
  create flow (F-23). Tapping a **ready** job opens its report (F-26); tapping a
  **non-ready** job opens live status (F-24); a **failed** job opens its status
  with the error.
- The status pill covers all backend statuses (`pending` →
  `resolving_address` … `fitting_planes` → `ready`/`failed`) mapped to the 3-tier
  treatment (working / done / failed) from the design direction.

## Testing requirements

- **Unit tests** (fake `APIClient`): the list view model loads + orders jobs;
  empty vs non-empty vs error states; the status→pill mapping for every status;
  tap routing (ready→report, non-ready→status).
- **Snapshot/manual:** the row, empty, and loading states in light mode (the
  visual states live in the manual test plan; logic is unit-tested).

## Manual setup required

- None beyond F-21's assets.

## Implementation notes (filled in by the building agent)

> Owned by the builder. Starts empty.
