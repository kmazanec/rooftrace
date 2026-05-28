# ADR-017: Accuracy validation harness — 15 LiDAR-covered demo addresses + 3 ground-truthed controls; report MAPE + P90

**Status:** Accepted · **Date:** 2026-05-27 · **Stretch:** no
**Supersedes:** none · **Superseded by:** none

## Context

The brief makes two related demands:

- Functional: "Accurate (within **±3%**)" on roof area.
- Submission: "**Performance metrics and benchmarks**" + "Test cases and
  validation results."

We *cannot* defend ±3% without an actual measurement against actual
ground truth. The CTO defense for the entire architecture rests on
this — "we got to ±X% on Y houses, here's the methodology" — and
without numbers, the rest of the architecture story is opinions.

Ground-truth sources, ranked by trustworthiness:

| Source | Trustworthiness | Cost | Practical for v1 |
|---|---|---|---|
| **Tape measure on a known roof** (your own house, with plans) | Gold standard | Free (your time) | 1–2 houses realistically |
| **Purchased EagleView Premium report** | ~1–3% — silver standard | ~$40–$80 per house | 1–2 reports realistic |
| **County assessor records (sq ft)** | Highly variable; often planimetric not pitched | Free | Useful as a coarse sanity check, not a metric |
| **3DEP LiDAR itself as ground truth for the satellite-only fallback** | Synthetic but defensible — measures Architecture A against Architecture B | Free | Use to validate the fallback path's error magnitude |

Reality: no single ground-truth source is enough. The harness has to
**triangulate** — a small number of high-trust references (tape +
EagleView) plus a larger set of LiDAR-covered addresses where we can
report consistency and structural validity (per-facet pitch within
expected ranges; total perimeter matches LiDAR's convex hull within
tolerance).

## Options considered

**A. 15 LiDAR-covered addresses + 3 EagleView/tape-measured controls;
report MAPE + P90.** Hand-pick the 15 to span simple/moderate/complex
roof complexity in 3DEP-covered metros. Buy one EagleView report on
a friend's house; tape-measure 1–2 simple roofs.
*Tradeoff:* costs ~$40–$80 (one EagleView report); ~half a day to
set up the test set; the right CTO-defense story.

**B. EagleView only (1–2 reports).** Cheaper; thinner story.
*Tradeoff:* fewer data points; no per-facet structural validation.

**C. LiDAR-as-ground-truth only (no purchased reports).** Free.
*Tradeoff:* validates only the satellite-fallback path against the
LiDAR primary path; can't honestly claim ±3% against ground truth.

**D. Skip formal validation; demo "type any address."** Reliance on
the demo gods.
*Tradeoff:* lethal in the writeup, where "performance metrics and
benchmarks" is graded explicitly.

## Decision

**A. 15 LiDAR-covered addresses + 3 ground-truthed controls.**

Specifically:

- **Test set:** 15 addresses pre-picked using the WESM index (ADR-003)
  for confirmed 3DEP coverage. Stratified:
  - **5 simple** roofs (1–2 facets, gable / hip standard residential).
  - **5 moderate** (3–5 facets, dormers, valleys).
  - **5 complex** (mansards, multi-wing houses, 6+ facets).
  - Geographically distributed: Lincoln NE (3), Chicago (3), a Sun
    Belt metro (3), a Pacific NW metro (3), Northeast (3).
- **Controls (3):**
  - **1 purchased EagleView Premium report** on a friend's house with
    known good 3DEP coverage. ~$80, one-time.
  - **1 tape-measured** simple roof (the candidate's own house or a
    cooperative friend's), with hand-drawn facet sketch.
  - **1 county-assessor cross-check** as a third (weaker) reference
    point.
- **Metrics reported:**
  - **MAPE (Mean Absolute Percentage Error)** on total area, against
    ground-truth sources (EagleView, tape).
  - **P90 of per-address percentage error** — i.e., 90% of measurements
    are within X% of ground truth.
  - **Structural validity:** % of test addresses where per-facet pitch
    is in [0°, 70°] (sanity), perimeter matches LiDAR-hull perimeter
    within tolerance, facet count is plausible vs. visual inspection.
  - **Fallback-path consistency:** for the 15 addresses, the
    satellite-fallback measurement is compared against the LiDAR
    measurement; honest report of "fallback within X% of LiDAR
    measurement on simple roofs, Y% on complex."
- **Harness:** Python script in `sidecar/validation/` that runs the
  full pipeline on each test address, persists results, and produces
  a Markdown report (`docs/VALIDATION_REPORT.md`) with the metrics
  + per-address breakdown.
- **Feature-detection model evaluation (per ADR-006):** the harness
  also owns the rooftop-feature-detection eval, including **pulling and
  hand-labeling its own dataset** — roof image tiles sourced through
  the production imagery provider (ADR-002) at the target GSD, diverse
  over roof complexity and feature presence (true-negative roofs
  included), labeled with the fixed vocabulary (chimney, vent,
  skylight, dormer, satellite_dish) and committed with a provenance
  manifest. That labeled set is scored with **per-class precision /
  recall and bounding-box IoU** across each candidate model behind the
  `FeatureDetector` interface. The production feature-detection model
  is chosen by these measured results — not assumed. This is a
  deliberate scope extension: no public benchmark covers this exact
  task, and the published grounding evidence (see ADR-006) shows general
  VLMs localize overhead small objects weakly while domain-trained
  detectors lead, so the model must be selected by measurement on our
  own labeled set.

## Rationale

This is the smallest harness that gives the CTO defense actual
numbers to stand on, plus a transparent methodology paragraph. The
combination of **a stratified test set + at least one true gold-
standard reference + at least one purchased silver-standard reference
+ structural consistency checks** is the right shape for a real
accuracy claim. Each layer alone would be challenged; together they
triangulate.

The 15-address size is calibrated to the build budget — small enough
to hand-curate (preventing the "demo gods" failure of random-address
selection that hits a townhouse), large enough to report meaningful
percentile statistics. Stratifying by complexity surfaces where the
architecture *fails* — which is more useful to the CTO than a uniformly
±X% number that hides edge cases.

Reporting MAPE *and* P90 is intentional: MAPE is the headline; P90
is the honesty layer ("90% of measurements are within X%, but the
worst case was Y% off, here's why"). Mature engineering reports both.

The CTO defense: *"±3% claim is grounded in a stratified test set,
two independent ground-truth methods, and a transparent metric. The
satellite-only fallback's accuracy is reported separately so we never
hide it. Worst-case errors are named and explained in the report."*

## Tradeoffs & risks

- **Test set size (15) is small** by ML benchmark standards. Mitigation:
  it's the right size for *integration validation* of a pipeline,
  not for *model evaluation*. Honest framing.
- **EagleView is silver-standard, not gold.** It has its own error.
  Mitigation: include at least one tape-measured gold-standard
  point; cite EagleView's published ±1–3% spec when comparing.
- **Stratified hand-curation introduces selection bias.** Mitigation:
  reported as "curated stratified test set" not "random sample";
  publicly listed addresses in `docs/VALIDATION_REPORT.md` so
  reviewers can re-test independently.
- **Coverage of edge cases.** Tree-occluded roofs, snow-covered
  roofs, very large commercial roofs are not in the test set.
  Mitigation: noted as "out of v1 scope" with the conditions under
  which the architecture is expected to degrade.
- **Harness re-runs cost money** (Modal GPU + VLM API calls × 15
  addresses × N runs). Mitigation: ~$2–$5 per full harness run;
  acceptable; cache pipeline intermediate results so a re-run on
  a metric-only change is essentially free.

## Consequences for the build

- **`sidecar/validation/`:**
  - `test_addresses.yaml` — the 15 addresses with metadata
    (complexity, region, expected LiDAR work unit).
  - `ground_truth.yaml` — EagleView + tape + assessor reference data
    keyed by address.
  - `run_harness.py` — runs the pipeline against each address,
    writes per-address results to `validation_results.json`.
  - `report.py` — computes MAPE / P90 / structural validity from the
    results JSON and produces `docs/VALIDATION_REPORT.md`.
- **CI integration:** the harness is *manually triggered* (not in
  every CI run — cost). A nightly Modal-budget-aware run is a v2
  feature.
- **Documentation deliverable:** `docs/VALIDATION_REPORT.md` is one
  of the writeup's "performance metrics and benchmarks"
  artifacts. Brief format: methodology paragraph, summary table
  (MAPE / P90 / per-complexity breakdown), per-address detail
  appendix.
- **Pipeline always emits `confidence` + `source`** on every facet
  and feature (already enforced by ADR-001/ADR-006); the harness
  validates that those fields are populated and align with the
  computed accuracy.
- **One test fixture per ground-truth source** (EagleView PDF
  parsed → reference, tape sketch → reference, assessor record →
  reference) so the reference data is reproducible.

## Amendment (2026-05-28) — build reconciliation

Two corrections discovered while building the harness:

- **The harness is a two-process split, not a Python-only script.**
  The measurement pipeline (`MeasurementOrchestrator`) and the feature
  detector (`FeatureDetector`) are Rails-resident, so a Python-only
  harness cannot produce a `Measurement` or run the detector. The
  data-producing half is therefore a **Rails rake task**
  (`lib/tasks/validation.rake`: `validation:run_measurements` and
  `validation:eval_features`) that emits JSON; the Python half
  (`sidecar/validation/*.py`) owns only the pure-function metrics and
  the Markdown report. (The `run_harness.py` named above is realized as
  the Ruby runner + `report.py`.)
- **Fallback-path consistency is DEFERRED.** The per-address comparison
  of the satellite-only fallback against the LiDAR primary needs a way
  to force the LiDAR-missing path on the orchestrator, which it does not
  yet expose. Rather than fork the orchestrator to fake it, this
  iteration **reports the fallback comparison as an honest gap** in
  `docs/VALIDATION_REPORT.md`. When a force-fallback flag lands on the
  orchestrator, the runner runs each address twice (primary + forced
  fallback) and the report's fallback section fills in. The CTO-defense
  framing ("the satellite-only fallback's accuracy is reported
  separately so we never hide it") is preserved by naming the gap, not
  by omitting it.
- **Feature-detection eval tiles** are served to the detector via signed
  Spaces URLs minted over the `cache/` prefix (`ImageryUrlMinter`), so
  the detector's host allowlist is satisfied with no SSRF-allowlist
  widening. The candidate sweep compares `google/gemini-2.5-flash`
  against `qwen/qwen2.5-vl-72b-instruct` (cross-architecture), both
  reachable by slug through the OpenRouter backend.
