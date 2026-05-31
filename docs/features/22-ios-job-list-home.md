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

## Build plan (planned 2026-05-31 · iteration `ios-full-app` · see `docs/BUILD-PLAN-ios-full-app.md`)

**Model tier:** Sonnet build → Opus review. Depends on F-21; ∥ F-26. Built against
`FakeAPIClient`. **Owns** `StatusIndicator` + the `route(for:)` rule (BUILD-PLAN §8–§9).

### Architecture decisions
- `JobListViewModel` (`@Observable @MainActor`) owns a `LoadState` enum — `idle / loading / loaded([JobSummary]) / error(message, stale:[JobSummary])` — so "error but keep rows" is representable, not three booleans that lie.
- The list is the `NavigationStack` root; rows push via `AppRouter.path` (`AppRoute`), not local `NavigationLink` bindings — uniform back-stack.
- `StatusIndicator` maps the decoded **`JobStatus`** (never the raw string) → 3-tier {working/done/failed}; glyph+label, never color-only (ADR-020; cc palette has no stoplight).
- Tap routing reads `JobStatus`: `.ready → .report(jobID)`, every other status → `.jobDetail(id)` (so `failed` reaches status-with-error). One `route(for:)` helper.
- Skeleton rows are real `JobRow`s under `.redacted(reason:)` gated on reduced-motion — not a spinner; skeleton ≡ loaded geometry.

### Adds
- View-model `JobListViewModel`; view `JobListView` (`.refreshable`, pinned bottom "＋ New measurement" `PrimaryButton` → `.createJob`, skeleton/empty/error states).
- Components (reserved by F-21): **`JobRow`**, **`StatusIndicator`** (owned here), **`EmptyStateView`**.
- Consumes F-21's `jobs() -> [JobSummary]`. Renders `JobSummary` = `{id, address, status, ready, totalAreaSqFt?, createdAt}` (mono area shown for ready only).

### Contrarian failure modes
- Status→pill must cover all 9 statuses (exhaustive `switch`, no `default` → a future stage is a compile error); the 6 processing stages collapse to **working**.
- Pull-to-refresh on error MUST keep loaded rows (`error(stale:)` carries the last array + an inline banner) — never wipe to skeletons → error.
- Ordering is client-enforced newest-first (don't trust server order).
- Empty (`[]`, guiding state) and error (inline affordance) are distinct screens.
- Mono area only for `ready` — omit the slot for processing (a `0`/`—` reads as a measured zero).

### Ordered build steps (test-first)
- [ ] `route(for: JobStatus) -> AppRoute` pure mapping + unit test all 9 statuses (ready→report, rest→jobDetail).
- [ ] `StatusIndicator` 3-tier mapping + unit test exhaustiveness over all statuses.
- [ ] `JobListViewModel` tests (FakeAPIClient): loads + orders newest-first; empty→empty state; throw→error keeping prior rows; refresh success replaces.
- [ ] Implement `JobListViewModel` (`LoadState`, `load()`/`refresh()`).
- [ ] Build `JobRow`, `StatusIndicator`, `EmptyStateView` (cc tokens, ≥44 pt, mono area).
- [ ] Build `JobListView` (skeleton/redacted, loaded list, error banner, empty state, pinned CTA).
- [ ] Wire 401 → `authStore.handleUnauthorized`; register as `NavigationStack` root.

### Test list
- **Unit (FakeAPIClient):** load+order; empty/non-empty/error-keeps-rows; status→pill for every status; `route(for:)` for every status; 401 routing.
- **Manual/snapshot (device):** row/empty/skeleton in light mode; pull-to-refresh feel; VoiceOver row as combined element; one-handed CTA reach.

### Contract touchpoints frozen
Owns `StatusIndicator` (consumed by F-24) + the `route(for:)` rule; freezes the rendered
`JobSummary` field set.

## Implementation notes (filled in by the building agent)

> Owned by the builder. Starts empty.
