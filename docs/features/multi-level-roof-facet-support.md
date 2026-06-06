# Feature: Multi-Level Roof Facet Support

**Status:** Done · **Date:** 2026-06-06

## What this delivers

Before: a fitted plane's point support collapsed to one minimum rotated rectangle, so disconnected roof sections could be bridged into one over-wide facet.

After: fitted planes keep connected plan-view support components, and neighboring supports only partition each other when they are local, non-parallel, same-level roof planes whose fitted surfaces actually meet. Adjoining or multi-level roof sections can produce bounded facets instead of broad strips.

Update: local roof features now partition against an evidence-backed roof-mass envelope built from all nearby plane-consistent LiDAR returns, so a facet can grow to visible eave returns even when its fitted inliers stop short.

## Requirements & Acceptance Criteria

1. Given one fitted roof plane has two disconnected inlier patches, when the roof model builds facets, then it emits one facet per connected patch rather than one bridging polygon.
2. Given an adjoining main roof and garage roof have two visible slopes each, when LiDAR supports both sections, then the model can emit four bounded facets.
3. Given existing clean gable, mansard, and outline-clipped cases, when plane fitting runs, then existing area and facet-count expectations remain stable.
4. Given a facet's fitted inliers stop short of the eave but nearby roof returns still match its plane, when the roof model partitions the local roof mass, then the facet extends to the evidence-backed roof edge.
5. Given nearby sections are at different elevations, when building roof-mass envelopes, then those sections do not partition or merge into each other's footprints.

## Approach

The change stays inside `sidecar/app/planefit/roof_model.py`. Plane fitting and topology merging remain unchanged. The roof-model candidate step now converts a plane's inlier points into connected buffered plan-view components and creates a candidate facet for each component. Plane-intersection partitioning now runs only against local neighboring supports that can form a real ridge/valley seam.

Decision: use Shapely buffering over the existing point set, not a new segmentation dependency. Why: Shapely is already core to this module, and the support split is a geometric post-process rather than an image-model concern.

The mass-envelope extension also stays inside `roof_model.py`. For each local partition group, it selects all points that are inside the refined outline, vertically close to one of the group's planes, and connected to the current support. It then regularizes those points to a minimum rotated rectangle, clips it to the outline, and only uses it when the area growth is bounded. Otherwise it falls back to the previous support union.

## Build Plan

- [x] Add a regression test for disconnected supports producing four bounded facets.
- [x] Replace single support rectangles with connected support components.
- [x] Add roof-mass envelope growth for same-level partition groups.
- [x] Add regressions for sparse eave inliers and different-elevation isolation.
- [x] Run impacted sidecar tests.
- [x] Run broader sidecar validation if impacted tests pass.

## Quality Bars

Security: n/a — no new input surface or external dependency.

Non-functional: support construction must stay bounded to residential roof crops; no network calls or heavyweight model work added.

Observability: existing roof-model diagnostics continue to report plane count, facet count, coverage ratio, and warnings.

## Decisions, Assumptions & Blockers

Decisions made:

- Connected support splitting is done after plane fitting, not by changing RANSAC, because the failure is an extent-modeling issue once a plane already has inliers.
- Partitioning ignores parallel planes and different-elevation supports because they represent separate roof levels, not competing surfaces on the same roof section.
- Weak residual planes must clear a higher confidence and area floor before becoming roof-model facets; otherwise simple gables fragment into small low-confidence slivers.
- Roof-mass growth is evidence-gated by plane residual, outline containment, component connectivity, and a bounded area ratio. This lets facets reach visible eaves without using the whole refined property outline as a blank check.

Assumptions:

- Fixed sub-meter support and seam tolerances are appropriate for public 3DEP residential roof returns and the existing synthetic fixture scale.
- LiDAR points that are close to an accepted roof plane are stronger evidence for eave extent than that plane's RANSAC inlier list alone.

Deferred / blockers:

- Comparing multiple imagery vendors or acquisition dates is useful future work for outline quality, but it is outside this LiDAR facet-support fix.

Validation:

- Replay of the cached Selworthy point cloud produced 4 facets instead of the persisted 3-facet duplicate/broad-strip result.
- Replay of the cached Winthrop point cloud produced 2 facets instead of the persisted 15-facet over-fragmented result.
- Sparse-eave regression grows the starved facet to the evidence-backed eave while keeping a two-facet gable.
- Different-elevation regression keeps overlapping main/garage sections isolated.
- `uv run pytest tests/test_planefit.py -q` passed: 50 tests.
- `uv run ruff check app/planefit tests/test_planefit.py` passed.
- `uv run pytest -q` passed: 435 tests.
