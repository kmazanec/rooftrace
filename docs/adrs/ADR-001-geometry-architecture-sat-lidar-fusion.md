# ADR-001: Use satellite + public LiDAR fusion as the headline geometry architecture

**Status:** Accepted · **Date:** 2026-05-27 · **Stretch:** no
**Supersedes:** none · **Superseded by:** none

## Context

The brief asks for roof measurements at **±3% area accuracy in under 5
minutes**, nationwide, with auto-detection of roof features (vents,
chimneys, dormers, skylights, sat-dishes), inside a **4-day build window**.

The incumbents — EagleView ($25–$90 per report, 24–48 hr turnaround) and
Hover ($20–$70, smartphone photogrammetry) — both reach their accuracy
through a **human-in-the-loop validation step** plus, in EagleView's case, a
proprietary imagery fleet. Pure-automated, pure-public-imagery at ±3% is
genuinely unsolved at commodity prices.

That establishes the real ceiling: ±3% on a curated demo set is achievable;
±3% nationwide is a research program, not a sprint. The architecture has to
hit the achievable target *and* be honest about where it falls short.

Three architectures are credible inside the budget — they differ in **what
3D information they have access to**:

- **A. Satellite + foundation models** — imagery only; pitch is inferred
  (shadow length, VLM guess). Cheap to build (~1.5 days); accuracy ±10–20%.
- **B. Satellite + LiDAR fusion** — public USGS 3DEP LiDAR gives real 3D
  surface geometry where coverage exists; ±1–3% area there, graceful
  fallback to A elsewhere. Fits the 4-day budget.
- **C. B + smartphone photogrammetry walk-around** — adds Hover-style SfM
  for tree-occluded / LiDAR-gap cases. Highest ceiling, ~6+ day scope.

CompanyCam's strategic ask (the $415M / $2B raise thesis) is "system of
record for the job + AI bundling that reduces wallet leakage to vendors
like EagleView." They are buying *a real measurement, not a hand-wave* —
the value to the contractor is replacing a $40 EagleView line item. An
estimate doesn't replace that line item; a measurement does.

## Options considered

**A. Pure satellite + foundation models** — Mapbox/NAIP tile → SAM2 polygon
→ GPT-4V guesses pitch from shadows → planimetric area / cos(pitch).
*Tradeoff:* ships fast, frees time for feature detection and polish, but
the accuracy story (`±10–20% area, pitch is a guess`) cannot replace an
EagleView purchase. A CTO who has heard the LLM-wrapper pitch will
discount this. Doesn't demonstrate the geospatial domain depth that
distinguishes the candidate.

**B. Satellite + LiDAR fusion** — USGS 3DEP point cloud (via COPC + PDAL),
cropped to the building footprint, RANSAC multi-plane fit per facet,
pitch from plane normals, area from projected facet extent, satellite
imagery for outline cross-check and visual context.
*Tradeoff:* eats most of the 4-day budget on geospatial plumbing
(geocode → CRS reproject → 3DEP WESM index → COPC fetch → spatial crop is
~5 hops); dies silently in LiDAR-gap counties unless a fallback is wired
explicitly; rewards us with real measurements, real pitch, real 3D
visualization. The wow moment is a side-by-side with an EagleView report
within ±1.6%.

**C. B + mobile photogrammetry hybrid** — adds Hover-style smartphone
walk-around (8–10 photos), SfM reconstruction (COLMAP/OpenSfM), ICP-align
to LiDAR, fill the tree-occluded / no-LiDAR cases.
*Tradeoff:* highest accuracy ceiling and most novel demo, but realistic
scope is 6+ days. COLMAP cold-start is brutal; WebXR / native AR is
fiddly; high risk of an unfinished demo with bugs in the most visible
part. **Demo-gods risk is real.**

## Decision

**B — Satellite + LiDAR fusion**, with:

- A **hard-coded graceful fallback to A-behavior** when LiDAR is missing or
  too sparse for the address; the UI explicitly surfaces "satellite-only
  estimate, ±10%, here's why" rather than silently degrading.
- **Mobile capture deferred** to a downstream consideration (Round 3). The
  C story can be told as a written roadmap section and an optional
  pre-recorded demo segment, **without committing build time to it**.

## Rationale

The brief asks for an *actual measurement*. Architecture B is the only path
in the 4-day budget that produces one: LiDAR gives you `(x, y, z)` points
on the roof surface and the math (RANSAC plane fit → pitch from plane
normal → area from projected extent) is geometry, not inference. That
matters for the CTO defense because it inverts the usual generative-AI
pitch: instead of "the model thinks this is 2,847 sq ft," we say "we
measured it; here are the LiDAR points; here's the EagleView report next
to ours at a 1.6% delta."

The honest fallback to A is what makes the architecture **defensible at
scale**, not just on a curated demo. Saying out loud "we land at ±3% where
3DEP has coverage, ±10% on satellite-only fallback, and we tell the user
which mode they're in" is the engineering-mature framing the CTO is
listening for. EagleView has the same problem (their imagery coverage is
not literally everywhere) — they just don't tell you. We tell the user.

This is also the architecture that **teaches the candidate geospatial as
a permanently valuable skill** (PROJ, PDAL, PostGIS, CRS arithmetic),
which is unfair-advantage territory for the Dev Forward consulting
practice.

## Tradeoffs & risks

- **Geospatial plumbing eats Day 1.** Address → LAZ tile is five hops
  through different coordinate systems. We pre-budget a full day for it
  and pre-pick 4–5 demo addresses in 3DEP-covered metros (Lincoln NE,
  Chicago, a coastal city) before writing code, so we don't discover the
  coverage gap mid-build.
- **RANSAC plane fitting fails on complex roofs** — mansards, hips,
  dormers can produce too many tiny planes or miss real ones. Mitigation:
  topology cleanup pass (merge near-coplanar facets within tolerance);
  test set covers a mansard and a complex multi-facet roof explicitly.
- **LiDAR class 6 (building) misclassifies in heavily-vegetated yards;**
  trees overhanging the roof create holes in the point cloud where the
  ground-truth surface should be. Mitigation: use the building footprint
  polygon to crop, then interpolate small (< 0.5 m²) holes; **flag the
  affected facets in the UI with a confidence indicator**, don't hide.
- **±3% is aspirational for general nationwide use**, even with this
  architecture. We will hit it on the demo set and *report honestly*
  what conditions are required (good LiDAR, simple-to-moderate roof).
  This honesty is itself a CTO-aligned signal.
- **C is genuinely a better product**, and choosing B means we leave
  differentiation on the table. We mitigate by writing the C roadmap into
  ARCHITECTURE.md and acknowledging in the demo that mobile is the v2
  story; reviewers respect "I know what's next" more than they punish
  "I didn't ship v2 in 4 days."

## Consequences for the build

- The geometry pipeline is structured as: **geocode → footprint lookup →
  LiDAR fetch (if available) → plane fit → measurements + 3D model**, with
  a sibling **fallback path** that does **footprint mask → pitch
  inference → planimetric-area math** when LiDAR is unavailable. Both
  paths terminate in the same measurement schema so the report renderer
  is path-agnostic.
- Every measurement carries a **`source` field**: `lidar+imagery` or
  `imagery_only`, plus a derived `confidence` score. This propagates to
  the report, the PDF, and the JSON export — non-negotiable.
- LiDAR ingestion uses **COPC over PDAL** (see ADR-003), not bulk LAZ
  download.
- We pre-pick **3–5 hand-curated demo addresses** with verified
  great-LiDAR coverage and a Plan-B "type any address; gracefully degrade"
  mode in the demo script.
- No mobile capture code in v1; the C story lives in ARCHITECTURE.md's
  "stretch features" and the writeup roadmap. If Round 3 elects a
  pre-recorded mobile demo segment, that's a video editing task, not a
  build task.
- Accuracy validation harness compares against a small ground-truth set
  (a purchased EagleView report on a friend's house + tape-measured
  controls); see Round 5.

## Amendment (2026-06-04) — LiDAR plane fits feed an outline-constrained roof model

The first implementation proved that independent RANSAC facet polygons are not a
strong enough accuracy boundary for the ±3% target. Plane normals were not the
only problem; facet extent and topology were. The LiDAR-primary path now inserts
an explicit roof-model layer after plane merging:

- Fit and merge planes from the cropped LiDAR cloud as before.
- Reproject the refined roof outline into the same local UTM model space.
- Build per-plane support polygons, clip them to the refined outline, and
  compute true surface area from plan-view area divided by `cos(pitch)`.
- Adapt the model back to the stable `Facet` contract for existing reports,
  viewers, exports, and PDFs.

*(amended 2026-06-04 — facet-boundary partition.)* The first slice set each
facet's extent to its own support's minimum bounding rectangle, then resolved
overlaps by "largest support claims first, trim the rest." That produced visibly
wrong extents in the 3D view: one facet of a gable over-extended past the ridge
while its neighbour was starved (and the inflated plan area skews the measurement,
since `area = plan_area / cos(pitch)`). Facet extent now comes from **partitioning
each cluster of adjacent supports by the planes' intersection seams**
(`roof_model.py`): two planes' shared boundary is the line where their fitted
surfaces are equal (`z_i == z_j` — the ridge/hip/valley), and each plane keeps the
side its own inlier centroid sits on (so the orientation auto-adapts to ridges vs
valleys, an over-extended neighbour is cut back to the seam, and a starved one
grows out to it). Non-adjacent supports are independent sections and never
reassign each other's area. Per-facet confidence still derives from the support's
point density, independent of the final partitioned extent.

This keeps the wire-compatible facet list while making the measurement derive
from a coherent roof footprint rather than each plane's unconstrained point
extent. `MeasurementGeometry` now carries optional `roof_model` diagnostics so
the model version, plane/facet/edge counts, coverage ratio, area method, and
model warnings can be inspected and persisted in provenance. Capture fusion also
accepts the prior refined outline and uses the same roof-model path when that
context is available.
