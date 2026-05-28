# Feature: Accuracy validation harness

**ID:** F-19 · **Roadmap piece:** F-19 · **Status:** Not started

## Description

Implements the accuracy-measurement methodology from
[ADR-017](../adrs/ADR-017-accuracy-validation-harness.md): a
stratified test set of 15 LiDAR-covered addresses (5 simple, 5
moderate, 5 complex) + 3 ground-truth controls (1 EagleView Premium
report, 1 tape-measured roof, 1 county-assessor cross-check). Runs
the full pipeline on each address, computes MAPE + P90 + structural
validity, and produces `docs/VALIDATION_REPORT.md` — the writeup's
"performance metrics and benchmarks" deliverable.

This is the feature that **defends the ±3% claim** with actual
numbers. Without it, the rest of the architecture story is opinions.

It also owns the **feature-detection model evaluation** required by
[ADR-006](../adrs/ADR-006-feature-detection-vlm-primary.md): a
hand-labeled set of rooftop features (the fixed vocabulary: chimney,
vent, skylight, dormer, satellite_dish) on nadir imagery at the target
GSD, scored with per-class precision/recall and bounding-box IoU, run
across each candidate model behind the `FeatureDetector` interface.
The production feature-detection model is **chosen by this evaluation,
not assumed** — published grounding benchmarks show general VLMs
localize overhead small objects weakly and domain-trained detectors
lead, so the choice must be measured on our own task.

## How it fits the roadmap

Wave 3 — can start as soon as F-10 (orchestrator) lands; runs in
parallel with the user surfaces (F-12, F-13, F-14) and with the
iOS/stretch features. Off the critical path; the validation report
is a writeup deliverable, not a runtime artifact.

## Dependencies (must exist before this starts)

- **F-10 Measurement orchestrator** — produces the measurements
  the harness scores.
- **F-09 VLM feature detection** — provides the `FeatureDetector`
  interface and v1 implementation that the feature-detection
  evaluation runs candidate models behind.

## Unblocks (what waits on this)

- **None** — terminal. The output is `docs/VALIDATION_REPORT.md`,
  consumed by the writeup deliverable and the demo's
  performance-metrics slide.

## Acceptance criteria

- **`sidecar/validation/test_addresses.yaml`** exists with the 15
  test addresses, each annotated with:
  - `address` (full street address).
  - `complexity` enum: `simple` | `moderate` | `complex`.
  - `region` (Lincoln NE, Chicago, …).
  - `expected_wesm_work_unit` (the 3DEP work-unit name expected
    to cover the address, pre-verified using
    https://apps.nationalmap.gov/lidar-explorer/).
- **`sidecar/validation/ground_truth.yaml`** has the 3 control
  references:
  - One EagleView Premium report (PDF parsed into structured
    reference data: total area, per-facet areas, pitches).
  - One tape-measured roof (hand-drawn facet sketch +
    measurements).
  - One county assessor record (square footage with caveats).
- **`sidecar/validation/run_harness.py`** runs the full pipeline
  on each of the 15+3 addresses; persists per-address results to
  `sidecar/validation/results/<timestamp>.json`. The script is
  CLI-invokable and respects Modal/VLM budget concerns (cache
  intermediate results so re-runs on metric-code changes are
  cheap).
- **`sidecar/validation/report.py`** consumes the results JSON and
  produces `docs/VALIDATION_REPORT.md` containing:
  - **Methodology paragraph** describing the test set, ground-
    truth sources, and metrics.
  - **Summary table:** MAPE on total area against ground truth
    (3 controls); P90 of percentage error across the 15 LiDAR-
    covered addresses (comparing primary path to a structural-
    consistency baseline since no per-address ground truth);
    per-complexity breakdown (simple / moderate / complex).
  - **Fallback-path consistency:** for each of the 15 addresses,
    the satellite-fallback (Architecture-A behavior) measurement
    compared against the LiDAR primary measurement, reported
    honestly per complexity stratum.
  - **Structural validity** — % of test addresses where per-facet
    pitch is in [0°, 70°], perimeter matches LiDAR convex-hull
    perimeter within tolerance, facet count is plausible vs.
    visual inspection.
  - **Per-address detail appendix:** for each address, the
    measurement output + the ground truth or LiDAR-derived
    consistency check.
  - **Honest worst-case naming:** name the worst-performing
    address and explain *why*. This is the honest-uncertainty UX
    applied to the validation report.
- **Test addresses published:** the address list in
  `test_addresses.yaml` is committed and listed in
  `VALIDATION_REPORT.md` so reviewers can re-test independently.
- **Reproducibility:** running `run_harness.py` twice on the same
  pipeline version produces consistent results (within
  measurement noise); document expected variance.

### Feature-detection model evaluation (ADR-006)

- **Labeled set:** `validation/feature_detection/labels.json` (or
  equivalent) holds hand-labeled ground-truth detections — the fixed
  vocabulary (chimney, vent, skylight, dormer, satellite_dish) with
  bounding boxes — over a set of nadir tiles at the target GSD. The
  label set and its provenance are committed and documented so the
  eval is reproducible.
- **Candidate sweep:** the eval runs each candidate model behind the
  `FeatureDetector` interface (selectable by the same `FEATURE_DETECTOR`
  env var the runtime uses) against the labeled set — at minimum more
  than one model, so the result is a comparison, not a single data
  point.
- **Metrics:** per-class **precision / recall** and **bounding-box IoU**
  (plus a count-level error since the report surfaces feature counts),
  reported per model and per feature class.
- **Output:** a feature-detection section in `docs/VALIDATION_REPORT.md`
  with the per-model / per-class table and an explicit statement of
  which model is selected as the production default **and the measured
  basis for that choice**. No model is named the production default
  without a number behind it.
- **Honest worst-case:** name the feature class and model combination
  that performs worst and why (e.g. small features at coarse GSD),
  consistent with the honest-uncertainty framing.

## Testing requirements

- **Smoke test:** `run_harness.py --address-limit 3` runs against
  the first 3 test addresses end-to-end as part of CI (manual
  trigger; not on every push due to Modal/VLM cost).
- **Report-generation test:** with a fixture results JSON,
  `report.py` produces a valid Markdown document with all the
  required sections.
- **Address-validation test:** asserts every entry in
  `test_addresses.yaml` has all required fields and that the
  `expected_wesm_work_unit` actually exists in the WESM index.

## Manual setup required

- **Purchase one EagleView Premium report** (~$80) on a friend's
  house with confirmed 3DEP coverage. Document the address in
  `ground_truth.yaml`; commit the EagleView PDF to
  `sidecar/validation/ground_truth/` (or a private link if PDF
  redistribution is licensed-restricted — verify).
- **Hand tape-measure one simple roof** (the candidate's own
  house if accessible). Record measurements + a sketch in
  `ground_truth.yaml`.
- **Pull county assessor record** for one address; document URL
  + extracted square footage.
- **Pre-pick the 15 test addresses** using the WESM viewer; verify
  each has 3DEP coverage before adding to `test_addresses.yaml`.
  Stratify per the ADR (5 simple, 5 moderate, 5 complex; 3 each
  in 5 regions).
- **Run the harness at least once before the demo** with the live
  Modal + Gemini credentials so the metrics in the writeup are
  current. Budget: ~$5 per full run.

## Implementation notes (filled in by the building agent)

> The agent implementing this feature records its implementation
> decisions and rationale here as it builds — chosen libraries/patterns
> within the architecture's constraints, trade-offs made, deviations
> from assumptions and why, and anything the next agent or the
> integrator needs to know. This section starts empty and is owned by
> the builder, not the planner. Cross-cutting discoveries that affect
> other features must also be propagated to ROADMAP.md or the
> architecture doc, not just left here.
