# Convergence report — Wave 5 stretches (`wave5-stretches`)

**Iteration:** Wave 5 — the two stretch features · **Date:** 2026-05-29
**Build branch:** `build/wave5-stretches` (barrier) · **Integration branch:** `integration/wave5-stretches`
**Contract barrier commit:** `19177a8` (merged `pipeline_schema` 0.4.0 — both F-17 + F-18 deltas)
**Assembled by:** cherry-pick only — zero merge commits, linear history.

## Batch result

Both stretch features SHIPPED on `integration/wave5-stretches`. One MR opened against `main`; **not** merged (the human merges it).

| Feature | Title | Tier | Status |
|---|---|---|---|
| **F-17** | Claim-defensibility PDF | sonnet→opus repair | **SHIPPED** |
| **F-18** | Server-side AR overlay | opus | **SHIPPED** |

## What this iteration adds

- **F-18 (AR overlay):** real `project-photo` sidecar render — pinhole projection
  of WGS84 facets into each photo's ARKit-local frame, SVG overlay (primary
  regression artifact) + PNG composite, trimesh ray-cast occlusion. Rails-
  authoritative pose-confidence gate (`PROJECTION_POSE_CONFIDENCE_MIN`, default
  0.7; the sidecar may only narrow it), `ProjectionJob`/`ProjectionOrchestrator`
  chained off fusion, `ProjectedOverlay` rows, viewer On-Site Visualization
  gallery with bidirectional facet↔gallery cross-highlight, and `json_export`
  1.1.0 (additive, public+auth parity per ADR-015).
- **F-17 (claim PDF):** provenance-derived `ReportMethodology` PORO, claim
  sections (methodology / limitations / site-visit) in the PDF, page-number
  footer chrome reconciled with the existing attribution footer, and an
  **honest** GPS site-visit block (see below). Consumes the barrier's
  composite-preferred evidence seam, so a job WITH F-18 projections renders
  composites and a job WITHOUT renders sidecar evidence thumbnails.

## Build-process note — F-17 was repaired before shipping

The autonomous build mis-based the F-17 worktree on **old `main` (0.3.0)** instead
of the frozen barrier, where it re-derived a divergent local `0.4.0` that deleted
F-18's schema fields and renamed the frozen Evidence Pydantic models — a high-
severity contract drift that correctly blocked the autonomous converge step (the
workflow shipped 0 features and its report emit hit a transient 529).

The human chose "fix F-17 first, ship both together." F-17 was rebuilt in a fresh
worktree off the barrier (`fix/f-17-on-barrier`), keeping **only** its genuine
claim-document layer on top of the barrier's canonical contract + evidence
infrastructure (the fork's duplicate schema / endpoint / client / seam were
discarded). Cherry-picked clean onto the integration branch. Verified by a human-
driven re-run of the full integrated suite below.

### Honesty fix folded into the repair (contrarian-review finding)

The fork asserted "GPS-verified within 12 m of the geocoded address" *unconditionally*
on any capture session, never reading `captures.gps` — a false factual claim in an
insurance document. The shipped version computes the haversine distance from each
capture's recorded GPS fix to `measurement.geocode` and asserts GPS verification
**only** when the nearest fix is genuinely within `CLAIM_PDF_VISIT_RADIUS_M`
(default 12 m); otherwise it states photos were captured but explicitly does NOT
assert GPS verification. Missing GPS → no claim.

## Integrated suite (run on the assembled batch, human-verified)

- **Sidecar (pytest):** `374 passed` — 0 failures.
- **Rails (rspec, full suite, real sidecar booted + viewer JS bundle built):**
  `611 examples, 0 failures, 1 pending`. The 1 pending is the pre-existing
  `skip` at `spec/requests/capture_sessions_spec.rb:227` (no-Content-Length
  multipart harness case — present before this iteration, commit `baae133`).
- **rubocop:** `150 files inspected, no offenses detected` (CI-gating).
- **brakeman:** `0 security warnings, 0 errors` (CI-gating).

## Smoke (F-18 path, driven live against the compose sidecar — from the build run)

- `/up` → 200; sidecar `/health` → 200.
- `POST /pipeline/project-photo` **no bearer** → **401** (shared-secret trust
  boundary holds).
- `POST /pipeline/project-photo` **bearer + empty body** → **422** with
  field-level validation against the frozen 0.4.0 contract — proves the real
  F-18 handler is wired and consuming the canonical contract (not a stub).

> `ops/compose.yaml` gained a documented heads-up about the prod boot-var gap +
> a known smoke-harness `DATABASE_URL` quirk surfaced during this smoke; the
> authoritative regression signal is the RSpec/pytest suites.

## Documented v1 deferrals (sanctioned by the approved build plan)

Both are deferred because they require a **future frozen-contract amendment**, not
a localized edit — exactly as the approved plan permits:

1. **F-18 feature-pin overlays.** The frozen `Feature` $def carries only
   `bbox_norm` against the *satellite* tile (no 3D/world position), so a feature
   cannot be projected into a photo's pinhole frame without a contract change.
   Facet overlays — the core deliverable — ship; pins wait for a `Feature` world
   position.
2. **F-18 occlusion-aware gallery dimming.** The frozen viewer
   `OnSiteVisualization` type carries no `occluded_facet_ids`, so v1 ships the
   index-level bidirectional highlight (the planned designated descope if it
   overran) rather than occlusion-aware dimming.

## Next step

Review and merge the MR. The transient per-feature worktrees/branches are torn
down once the MR is open; the barrier branch `build/wave5-stretches` is retained
until merge. Landing this completes the Wave 5 stretch features — the last unbuilt
roadmap pieces.
