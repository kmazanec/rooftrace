# Feature: Accuracy validation harness

**ID:** F-19 · **Roadmap piece:** F-19 · **Status:** Harness built & merged to main; docs/VALIDATION_REPORT.md pending the human-gated data run (EagleView/tape/assessor controls + feature-detection labeling) · 2026-05-28

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

- **Dataset acquisition (pull the roof imagery):** assemble a test set
  of nadir roof image tiles, sourced through the **same imagery
  provider the pipeline uses in production** (per
  [ADR-002](../adrs/ADR-002-imagery-providers-naip-mapbox.md)) so the
  eval GSD (~30–60 cm) and image characteristics match what the
  detector sees at runtime — no mismatched stock/aerial imagery. Pull a
  diverse set (target on the order of dozens of roofs, not a handful):
  spanning roof complexity (simple → complex) and deliberately
  including roofs that contain each feature class **and** roofs that
  contain none (true negatives matter for precision). A small fetch
  script (e.g. `validation/feature_detection/pull_tiles.py`) takes an
  address/bbox list and writes the tiles + a manifest, so the pull is
  reproducible and the provenance (provider, capture date, GSD, source
  URL/tile id per image) is recorded. Imagery that can't be
  redistributed is referenced by manifest, not committed.
- **Labeling:** hand-label every pulled tile with ground-truth
  detections — the fixed vocabulary (chimney, vent, skylight, dormer,
  satellite_dish) with bounding boxes — into
  `validation/feature_detection/labels.json` (or equivalent). Document
  the labeling protocol (who labeled, the per-class definition used,
  how ambiguous/occluded features were handled) so the labels are
  reproducible and auditable; the label file and protocol are
  committed. The dataset (manifest + labels) is the ground truth the
  candidate models are scored against — pulling and labeling it is part
  of this feature's work, not a precondition assumed to exist.
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
- **Feature-dataset integrity test:** asserts every labeled tile has a
  matching manifest entry (and vice versa), that all label bboxes are
  in-bounds and use only the fixed vocabulary, and that the set
  includes at least one true-negative tile (no features) — so a broken
  or partial dataset fails loudly rather than silently skewing the eval.

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
- **Pull + hand-label the feature-detection dataset.** Run the tile
  pull against the production imagery provider for the chosen roofs,
  then hand-label every tile with ground-truth feature bboxes per the
  documented protocol. This is real human labeling effort (budget for
  it like the EagleView/tape-measure controls) — the eval cannot run
  without it, and its quality bounds the trustworthiness of every model
  comparison.
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

### Build notes (2026-05-28)

- **Two-process architecture (the decisive correction).** The pipeline +
  feature detector are Rails-resident, so the data-producing half is a Rails
  rake task (`lib/tasks/validation.rake`): `validation:run_measurements` (creates
  a Job per address, runs `MeasurementOrchestrator.call` inline, serializes the
  persisted Measurement) and `validation:eval_features` (sweeps candidate model
  slugs through `FeatureDetector::OpenRouter`). The Python half
  (`sidecar/validation/`) is pure-function metrics + Markdown. Propagated to
  ADR-017 as an amendment.
- **predominant_pitch_degrees is DERIVED** in the runner (`ratio_to_degrees`,
  `atan(ratio/12)`); only the ratio is stored (schema contract).
- **Fallback-path consistency DEFERRED** (human resolution): the orchestrator
  exposes no force-LiDAR-missing path, so the comparison is reported as an honest
  gap in `VALIDATION_REPORT.md` rather than faked. The runner + report are
  structured so that when a force-fallback flag lands, both measurements per
  address fill the section in. ADR-017 amended.
- **Feature-detection eval tiles via signed Spaces URLs** (human resolution): the
  sweep uploads each tile under the `cache/` prefix and mints a signed URL with
  `ImageryUrlMinter`, so the detector's host allowlist is satisfied with NO
  SSRF-allowlist widening. Candidate sweep = `google/gemini-2.5-flash` +
  `qwen/qwen2.5-vl-72b-instruct` (cross-architecture, both reachable by slug).
- **Model selection metric = unweighted mean F1 (v1).** Recall-weighting (a
  missed feature is worse than a false positive for the report) is a documented
  v2 open question. No model named the production default without a measured F1.
- **DB hygiene.** The runner creates Job/Measurement rows; it is documented to
  run against a dedicated harness DB. The runner specs use transactional fixtures
  + a stubbed orchestrator, so the test DB stays clean and no live creds are
  needed; full runs are manual-only.
- **CI.** Fast schema/metric/report/eval-scorer tests run under the existing
  `sidecar_test` `uv run pytest` (no `slow` markers). A new `when: manual`
  `validation_harness` job runs the full Rails-rake + Python harness with live
  creds, gated behind approval (cost).
- **Manual-setup gates.** `test_addresses.yaml`, `ground_truth.yaml`,
  `manifest.json`, `labels.json` ship with `todo`/`seed` placeholders; the
  integrity tests check structure now and flip to live gates once the human fills
  real addresses/controls/labels (see `sidecar/validation/README.md`).
- **Test evidence.** sidecar: 292 passed; Rails: 368 examples, 0 failures;
  rubocop + brakeman clean.

---

## Build plan (approved) — planned 2026-05-28

> Generated by the plan-iteration pass and reconciled into the shared
> contract manifest in [`../BUILD-PLAN.md`](../BUILD-PLAN.md). The frozen
> contracts + shared barrier in that manifest take precedence over any
> step below if they disagree. **Approve before building.**

> **Human resolutions (2026-05-28) — apply these:**
> - **Fallback-consistency table is DEFERRED** (no orchestrator force-`LIDAR_MISSING` override this iteration). Do NOT modify the orchestrator. Record the deferral in ADR-017 and in `VALIDATION_REPORT.md` as an honest gap; build the rest of the harness.
> - **Model sweep = `google/gemini-2.5-flash` (default) + `qwen/qwen2.5-vl-72b-instruct`** — both reachable by slug through the OpenRouter `FeatureDetector` backend; a cross-architecture comparison.
> - **Serve eval tiles via signed Spaces URLs** to `detect(image_tile_url:)` (reuse the `ImageryUrlMinter` pattern) — do NOT widen the SSRF host allowlist.
> - The human data-collection (addresses, EagleView, tape-measure, tile labeling, harness DB) is a parallel pre-build track that gates only the final report, not the code.

**Recommended build model tier:** `opus` — The decisive language-boundary correction (runner is a Rails rake task, not Python-calls-sidecar), force-fallback dependency, allowlisted-tile-URL feeding detect(), and honest statistical framing — architecture judgment, not mechanical.

### Summary

F-19 is a two-track validation harness that defends the +/-3% area claim and selects the production feature-detection model by measurement. The decisive correction from reading the code: feature detection is Rails-resident (app/services/feature_detector.rb -> FeatureDetector.build.detect(image_tile_url:, roof_polygon:), selected by FEATURE_DETECTOR env, swappable by OpenRouter model slug), and the orchestrator (MeasurementOrchestrator.call(job)) assembles the Measurement in Ruby. A sidecar-only Python harness CANNOT produce a Measurement or run the detector. So both drafts' "call the sidecar from Python" path is wrong. The clean architecture is a two-process split that respects the language boundary: (1) a Rails-side runner (a rake task lib/tasks/validation.rake + a plain Ruby driver under sidecar/validation/ is wrong location — it must be a Rails task) that creates a Job per test address, runs the real orchestrator, and serializes each persisted Measurement to JSON, plus a candidate-model sweep that loops FEATURE_DETECTOR slugs through the real Ruby FeatureDetector against labeled tiles; and (2) Python in sidecar/validation/ that owns pure-function metrics (MAPE/P90/IoU/precision/recall/structural validity) and Markdown report generation, consuming the runner's JSON. Test-first Python metrics with known-answer fixtures; schema/integrity tests for the YAML/JSON config files. The heavy items (EagleView purchase, tape-measure, address pre-pick, NAIP tile pull + hand-labeling) are human-gated manual setup, sequenced in a pre-build phase. No DB migrations, no Rails model changes, no new routes. F-19 does NOT need the Report row (it reads Measurement directly) — that cross-feature gap belongs to F-12/F-13/F-14.

### Dependencies (verified present in code)

- F-10 MeasurementOrchestrator (app/services/measurement_orchestrator.rb) — landed; MeasurementOrchestrator.call(job) assembles + persists the Measurement the harness scores.
- F-09 FeatureDetector interface (app/services/feature_detector.rb + app/services/feature_detector/open_router.rb) — landed; FeatureDetector.build selectable by FEATURE_DETECTOR env, OpenRouter backend reaches any model by slug.
- Job model (app/models/job.rb) — Job.create!(address:), enum status, latest_measurement, advance_to!; orchestrator flips to :ready.
- shared/pipeline_schema.json @ 0.3.0 — Measurement/Facet/Feature/GeometrySource/Confidence $defs; the contract report.py validates against.
- sidecar/app/imagery/naip.py (fetch_naip_png) — the production NAIP fetch pull_tiles reuses.
- sidecar/app/lidar/wesm.py + sidecar/tests/fixtures/f06/wesm_index.json — WESM work-unit names + a frozen index to validate test_addresses against.
- Local PostGIS DB on localhost:5433 (CLAUDE.md) — the runner needs a DB to persist Measurements; live Modal + OpenRouter creds for full runs.

### Shared-contract touch points

> These are reconciled and frozen in `BUILD-PLAN.md`. Build to the frozen
> signatures there, not to prose in this spec.

- Measurement contract (shared/pipeline_schema.json Measurement $def @ pipelineSchemaVersion 0.3.0 + db/structure.sql columns): the runner serializes persisted Measurement rows and report.py reads them. F-19 must pin/assert the schema version it validates against and fail loud on mismatch. No version bump owned by F-19.
- Force-fallback (LIDAR_MISSING) capability on MeasurementOrchestrator: ADR-017 requires comparing the satellite-only fallback measurement against the LiDAR primary per address. If the orchestrator has NO way to force the fallback path, F-19 needs the orchestrator owner to expose one (env flag or kwarg). MUST be confirmed before the runner is built — F-19 will not reimplement the fallback.
- FeatureDetector interface is Rails-resident (app/services/feature_detector.rb): the eval sweep drives the Ruby FeatureDetector.build.detect(image_tile_url:, roof_polygon:) by model slug, NOT a Python detector. detect takes an image URL (not a numpy array) and the URL must pass the imagery host allowlist (ImageryUrlMinter / FeatureDetector IMAGE_TILE_HOST_ALLOWLIST) — the harness must host labeled tiles at an allowlisted URL or the allowlist must accept the eval tile host. Confirm reachable candidate model slugs through the OpenRouter backend.
- Fixed feature vocabulary: labels.json + eval must use exactly FeatureDetector::KNOWN_LABELS (chimney, vent, skylight, dormer, satellite_dish) and the Feature $def bbox_norm [x0,y0,x1,y1] in [0,1] convention. Single source of truth is the Ruby constant + the schema; F-19 mirrors, never redefines.
- NAIP imagery path (ADR-002, sidecar/app/imagery/naip.py): pull_tiles reuses the production NAIP fetch so eval GSD/provider match runtime and stay SSRF-allowlisted. No new imagery endpoint.
- WESM work-unit identifiers: expected_wesm_work_unit in test_addresses.yaml must match WorkUnit.name from the WESM index (sidecar/app/lidar/wesm.py); validate against a committed frozen WESM index fixture, not a live fetch in CI.
- Report row is NOT an F-19 dependency: F-19 reads Measurement directly via the orchestrator, so it does NOT need /r/:token -> Report -> latest_measurement. The Report-creation gap (orchestrator never creates a Report) is owned by F-12/F-13/F-14, flagged here only so it is not assumed to be F-19's problem.

### Build steps

- [x] **Scaffold sidecar/validation/ package + results dir**
  - Create sidecar/validation/__init__.py, sidecar/validation/feature_detection/__init__.py, sidecar/validation/results/.gitkeep, sidecar/validation/fixtures/.gitkeep. Add a [tool.pytest.ini_options] note or confirm sidecar/pyproject.toml testpaths=['tests'] still finds tests; place all F-19 pytest files under sidecar/tests/ (NOT under sidecar/validation/) so existing pytest config discovers them. Do NOT reference any F-NN id in committed files (CLAUDE.md rule); reference ADR-017/ADR-006/ADR-002 only.
- [x] **Add Python deps for metrics + config parsing to sidecar/pyproject.toml**
  - Add pyyaml (read test_addresses.yaml/ground_truth.yaml) and jsonschema (already a dev dep) to the runtime or dev group as appropriate; numpy + shapely already present (use numpy.percentile for P90, shapely for bbox IoU, or hand-roll IoU). Run `cd sidecar && uv sync` and confirm imports resolve. No scipy needed (numpy.percentile suffices).
- [x] **Write sidecar/validation/metrics.py (pure functions, no I/O)**
  - Implement: mape(truth: list[float], pred: list[float]) -> float; p90(pct_errors: list[float]) -> float (numpy.percentile q=90); per_complexity_breakdown(records, key) -> dict; bbox_iou(box_a, box_b) -> float (normalized [x0,y0,x1,y1] in [0,1]); precision_recall_f1(pred_dets, gt_dets, iou_threshold=0.5) -> per-class dict (greedy IoU>=0.5 matching, same class); count_error(pred, gt) -> int; structural_validity(measurement) -> {pitch_valid_pct, perimeter_within_tol, facet_count_plausible} using thresholds pitch in [0,70] degrees and perimeter within +/-5% of LiDAR hull perimeter. Each function has a docstring stating the formula. NO network, NO file reads.
- [x] **TEST-FIRST: sidecar/tests/test_validation_metrics.py**
  - Write before/with metrics.py. Known-answer fixtures: mape([100,100,100],[100,110,95])==pytest.approx(0.05); p90 of [1..100]==pytest.approx(90, rel/abs tolerance for interpolation method, assert chosen method explicitly); bbox_iou([0,0,1,1],[0,0,1,1])==1.0 and ([0,0,1,1],[0,0,0.5,0.5])==0.25; precision_recall_f1 on a 3-tile mock (perfect detector -> p=r=1.0; one FP -> p<1; one FN -> r<1); values all in [0,1]. Run: cd sidecar && uv run pytest tests/test_validation_metrics.py -v.
- [x] **Write sidecar/validation/test_addresses.yaml (template + committed real entries)**
  - Schema per spec: list of {address, complexity (simple|moderate|complex), region, expected_wesm_work_unit}. Commit the 15 stratified entries (5/5/5; 3 each across Lincoln NE, Chicago, Sun Belt, Pacific NW, Northeast). Pre-picking + WESM verification is MANUAL SETUP — the builder commits the structure with placeholder entries and the human fills/verifies real addresses against https://apps.nationalmap.gov/lidar-explorer/. The expected_wesm_work_unit values must match the WESM index work-unit `name` field (see sidecar/app/lidar/wesm.py WorkUnit.name and fixture sidecar/tests/fixtures/f06/wesm_index.json, e.g. 'NE_Lancaster_2020').
- [x] **Write sidecar/validation/ground_truth.yaml + README_GROUND_TRUTH.md**
  - ground_truth.yaml: 3 keyed entries (eagleview, tape_measured, county_assessor) with address (FK into test_addresses.yaml), method, total_area_sq_ft, per_facet_areas (list), predominant_pitch_ratio, source_url/notes, caveats. Mark as MANUAL-SETUP. README_GROUND_TRUTH.md documents the 3 human steps (buy 1 EagleView Premium ~$80; tape-measure 1 simple roof; pull 1 county assessor record) and states the builder does NOT automate these. Note EagleView PDF -> structured data is hand-transcription (no committed PDF parser); commit the PDF to sidecar/validation/ground_truth/ only if licensing permits, else reference by note.
- [x] **TEST-FIRST: sidecar/tests/test_validation_config.py (schema + referential integrity)**
  - Tests: (a) every test_addresses.yaml entry has all required fields, complexity in enum, region non-empty; (b) every expected_wesm_work_unit appears in a committed WESM index fixture (reuse/extend sidecar/tests/fixtures/f06/wesm_index.json or commit a frozen snapshot under sidecar/validation/fixtures/wesm_index.json) — fail loud on unknown work unit; (c) every ground_truth.yaml address exists in test_addresses.yaml and area>0, pitch_ratio>=0.0; (d) placeholder-tolerance: tests assert structure even before real addresses land (use a marker to xfail/skip entries explicitly flagged TODO so CI is green pre-setup but the gate is real once filled). Mark live-WESM-fetch variants pytest.mark.slow.
- [x] **Write the Rails-side measurement runner as a rake task (lib/tasks/validation.rake)**
  - CRITICAL ARCHITECTURE: the pipeline + feature detection are Rails-owned, so the runner is Ruby, NOT Python. Implement a rake task `validation:run_measurements` that: reads sidecar/validation/test_addresses.yaml; for each address (respect ADDRESS_LIMIT env for the smoke run), creates a Job (Job.create!(address:)), runs MeasurementOrchestrator.call(job) synchronously (NOT GeometryJob.perform_later — run inline so the runner blocks until ready/failed), reads job.latest_measurement, serializes the full Measurement row (all columns: total_area_sq_ft, predominant_pitch_ratio, facets, features, source, confidence, warnings, total_perimeter_ft, lidar, geocode, parcel_polygon, provenance) to sidecar/validation/results/<timestamp>.json under {timestamp, schema_version, addresses:[{address, complexity, region, measurement, errors?}]}. Cache by address+source_fingerprint so re-runs skip pipeline. Per-address try/rescue records errors[] and continues. Honor CLAUDE.md: do NOT leave committed Job rows in the dev/test DB (run against a dedicated harness DB or wrap in clearly-namespaced records); document the run DB in README. Accept LIDAR_LIVE/IMAGERY_LIVE/Modal/OpenRouter creds via env.
- [~] **Add fallback-path consistency capture to the runner** — DEFERRED (human resolution 2026-05-28): no orchestrator force-fallback this iteration; reported as an honest gap in VALIDATION_REPORT.md + ADR-017 amendment.
  - Per ADR-017 + spec: for each of the 15 addresses also produce the satellite-only (Architecture-A / LiDAR-missing) measurement to compare against the LiDAR primary. Verify whether MeasurementOrchestrator already supports forcing the fallback path (grep showed fallback_measurement stage + a join/source switch). If a force-fallback flag does NOT exist, this is a SHARED CONTRACT NEED on the orchestrator (a way to force LIDAR_MISSING) — flag it; do not silently reimplement. If it exists, the runner runs each address twice (primary + forced-fallback) and stores both measurements so report.py computes the consistency delta.
- [x] **Write sidecar/validation/report.py (consumes results JSON, emits docs/VALIDATION_REPORT.md)**
  - Pure Python: load latest (or named) sidecar/validation/results/<timestamp>.json, compute metrics via metrics.py, write docs/VALIDATION_REPORT.md with sections: Methodology (stratified hand-curated test set per ADR-017, ground-truth sources, metric definitions, expected variance/non-determinism note); Summary Table (MAPE on the 3 controls; P90 of pct error across the 15; per-complexity breakdown); Fallback-Path Consistency (primary vs forced-fallback delta per complexity stratum); Structural Validity (% pitch in [0,70], perimeter-within-tol, facet-count plausible); Per-Address Detail Appendix (lists all 15 addresses so reviewers can re-test); Honest Worst-Case Naming (worst-MAPE address named, explanation grounded in measurement.warnings + source/confidence, NOT hand-wavy); a Confidence/Source assertion that every facet+feature carries source+confidence (honest-uncertainty cross-cutting rule). Surface attribution/provenance (NAIP, MS Footprints, Mapbox, Nominatim, Regrid, USGS 3DEP) read from measurement.provenance. Address-completion-failures listed before metrics if any errors[].
- [x] **TEST-FIRST: sidecar/tests/test_validation_report.py**
  - Hand-craft a fixture results JSON (3 addresses, synthetic measurements with known MAPE/P90 and one forced worst case) under sidecar/validation/fixtures/sample_results.json. Call report.py against it (writing to a tmp path, not the real docs/VALIDATION_REPORT.md, to avoid polluting the repo in CI). Assert: all required section headers present; the summary table contains the expected MAPE/P90 strings; the worst-case section names the synthetic worst address; markdown parses (basic header/line checks).
- [x] **Write sidecar/validation/feature_detection/pull_tiles.py + manifest**
  - CLI taking an address/bbox list (subset of test_addresses + extra feature-diverse roofs). Fetch nadir tiles via the SAME production imagery path the pipeline uses (NAIP via AWS Open Data per ADR-002; the live fetcher is sidecar/app/imagery/naip.py — reuse fetch_naip_png so GSD/provider match runtime and stay on the allowlisted host). Write tiles to sidecar/validation/feature_detection/imagery/ + manifest.json recording per-tile {tile_id, address, bbox, gsd_cm, provider:'USDA NAIP', capture_date, source_url, license:'public domain'}. Ensure diversity incl. true-negative roofs. NAIP is public domain so tiles may be committed; non-redistributable sources referenced by manifest only. SSRF: pull_tiles only fetches from the NAIP S3/STAC hosts the orchestrator uses — assert this in a test.
- [x] **Write sidecar/validation/feature_detection/labels.json + LABELING_PROTOCOL.md**
  - labels.json schema: {tile_id: {image_path, width_px, height_px, features:[{label in {chimney,vent,skylight,dormer,satellite_dish}, bbox_norm [x0,y0,x1,y1] in [0,1], occluded:bool, ambiguous:bool}]}}. Must use the SAME fixed vocabulary as FeatureDetector::KNOWN_LABELS (app/services/feature_detector.rb) and the same bbox_norm convention as the Feature $def in shared/pipeline_schema.json. LABELING_PROTOCOL.md documents per-class definitions, bbox conventions, occlusion handling, who/when labeled, QA spot-check. Hand-labeling is MANUAL human work — builder commits the protocol + an empty/seed labels.json; the human fills it. Include >=1 true-negative tile.
- [x] **TEST-FIRST: sidecar/tests/test_feature_dataset_integrity.py**
  - Assert: every labels.json tile_id has a manifest entry and vice versa (no orphans); all bbox_norm in [0,1]; all labels in the fixed vocabulary (chimney/vent/skylight/dormer/satellite_dish — assert it matches the vocab, ideally cross-checked against a committed copy of KNOWN_LABELS); >=1 true-negative tile; manifest entries have all provenance fields; pull_tiles only references allowlisted NAIP hosts (SSRF). Mark the live-NAIP-fetch test pytest.mark.slow + skip by default.
- [x] **Write the Rails-side feature-detection candidate sweep (rake task validation:eval_features)**
  - CRITICAL: the detector is Ruby (FeatureDetector.build, selectable by FEATURE_DETECTOR env, swappable by OpenRouter model slug). So the candidate sweep is a Rails rake task that, for each candidate model slug (a config list, e.g. several OpenRouter slugs since FeatureDetector::OpenRouter reaches any model by slug per the file comment), runs FeatureDetector.build.detect(image_tile_url:, roof_polygon:) on each labeled tile (minting a signed URL for the committed tile, or serving it over a local file URL the detector accepts — verify ImageryUrlMinter/host allowlist constraints; detect takes a URL not an array, so the harness must host tiles at an allowlisted URL or extend the allowlist for the eval). Write raw detections to sidecar/validation/feature_detection/predictions_<slug>.json keyed by tile_id. NOTE the coupling: candidate models other than the default require either a config list of slugs the OpenRouter backend accepts or new FeatureDetector backends — confirm which slugs are reachable.
- [x] **Write sidecar/validation/feature_detection/eval_models.py (Python scorer)**
  - Pure Python: load labels.json + each predictions_<slug>.json, score per-class precision/recall/F1 (IoU>=0.5 match via metrics.py), mean bbox IoU on TPs, and count error. Output sidecar/validation/feature_detection/eval_results.json {model: slug, per_class:{label:{precision,recall,f1,iou,count_error}}, overall_f1, rank}. Select production default = highest mean-across-classes F1 (document that unweighted F1 is v1 and recall-weighting is a v2 open question). NO model selected without a number.
- [x] **TEST-FIRST: sidecar/tests/test_eval_models.py**
  - Fixture: a tiny labels.json + a deterministic predictions JSON for 2 mock model slugs (one perfect, one with a known FP/FN). Run eval_models.py, assert eval_results.json has per-class precision/recall/f1/iou/count_error all in [0,1] (or >=0 for count_error), overall_f1 computed, ranks assigned, and the perfect model is selected. No live VLM calls.
- [x] **Extend report.py with the feature-detection section**
  - After the measurement sections, append: Dataset Acquisition (N tiles from NAIP at ~X cm GSD, diversity + true-negatives, reference LABELING_PROTOCOL.md); Candidate Models table (Model | Precision | Recall | IoU | F1 per class + overall); Selected Production Model (explicit 'model <slug> selected, overall F1 <n>' + rationale); Honest Worst-Case (feature class x model that performs worst + why, e.g. small features at coarse GSD). Update test_validation_report.py to feed a mock eval_results.json and assert these sections render.
- [x] **Write sidecar/validation/README.md + wire CI smoke target**
  - README.md: overview of the two tracks; the two-process architecture (Rails rake runner produces results JSON; Python computes metrics + report); manual-setup checklist with order (tape-measure first ~1-2h; order EagleView ~$80 1-2 days; hand-label in parallel ~4-6h; pre-pick addresses); how to run smoke vs full; cost (~$5/full run, smoke ~$1); caching + reproducibility/variance note; cross-ref ADR-017/ADR-006/ADR-002. CI: add a manual-trigger .gitlab-ci.yml job that runs the schema/metrics/report/eval-scorer pytest under `cd sidecar && uv run pytest tests/test_validation_*.py -m 'not slow' -v` (no live fetch, no Modal/VLM); a separate manual full-harness job (Rails rake tasks + Python) gated behind explicit approval due to cost. Keep main `verify` stage unchanged in behavior — the fast schema/metric tests run with the existing sidecar pytest invocation.

### Test strategy

Test-first for all pure Python (metrics.py, report.py, eval_models.py) and all config/dataset integrity, since those are deterministic and mechanical. Python tests live in sidecar/tests/test_validation_*.py + test_eval_models.py + test_feature_dataset_integrity.py and run under the existing `cd sidecar && uv run pytest` config (testpaths=['tests']). Fast tests (schema validation, metric known-answers, report-from-fixture, eval-from-fixture-predictions) are unmarked and run in CI; live-fetch + live-VLM + full-pipeline tests are pytest.mark.slow and skipped in normal CI, triggered manually. Known-answer metric fixtures: MAPE 0.05, P90 90, IoU 1.0/0.25, precision/recall on perfect/FP/FN mocks. Report + eval tests consume hand-crafted fixture JSON (no network). The Rails rake runner is exercised only via a manual smoke (validation:run_measurements with ADDRESS_LIMIT=1) end-to-end and is not in fast CI (cost + needs live creds). Acceptance criteria from the spec map 1:1: test_addresses schema/WESM test, ground_truth schema test, report-generation test (all required sections), feature-dataset integrity test (orphans, bbox bounds, vocabulary, >=1 true-negative). No Rails model/migration/route tests because F-19 adds none.

### Risks

- Wrong-language harness: both source drafts proposed calling the sidecar from Python to produce a Measurement. That cannot produce features (detector is Rails) or the assembled Measurement (orchestrator is Rails). Mitigation: runner is a Rails rake task; Python only does metrics + report. This is the single biggest correction.
- detect() takes an image URL, not a tile array: the feature-detection sweep cannot just pass a local numpy image. The harness must serve labeled tiles at an allowlisted URL (ImageryUrlMinter / host allowlist). If the allowlist rejects the eval host, the sweep fails. Mitigation: confirm the allowlist path early; possibly mint signed Spaces URLs for the committed tiles.
- Force-fallback may not exist on the orchestrator: ADR-017's fallback-consistency metric needs a way to force LIDAR_MISSING. If absent, the fallback table cannot be produced honestly. Mitigation: confirm with orchestrator owner; if absent, scope the fallback table as a documented gap rather than fake it.
- Manual-setup labor dominates wall-clock: EagleView (1-2 days delivery), tape-measure, address pre-pick, hand-labeling (4-6h). Code can be done while data is missing -> report cannot generate. Mitigation: split human-gated setup into a pre-build phase, start it in parallel.
- Candidate model reachability: ADR-006 requires >1 model. Only the OpenRouter backend exists; other models must be reachable by slug through it or need new backends. Mitigation: pick >=2 OpenRouter-reachable slugs; do not assume a non-existent backend.
- DB pollution: CLAUDE.md forbids leaving committed Job rows in the dev/test DB. The runner creates Jobs. Mitigation: use a dedicated harness DB or namespaced/cleaned records; document it.
- VLM/Modal non-determinism + cost: same address varies call-to-call; ~$5/full run. Mitigation: cache by source_fingerprint; smoke = ADDRESS_LIMIT 3; full run is manual-trigger only.
- Small dataset (15 addresses, dozens of tiles) is not statistically robust. Mitigation: honest framing as integration validation, not model benchmarking; publish addresses for re-test.
- Worst-case explanation hand-waviness undermines the honest-uncertainty story. Mitigation: ground the explanation in measurement.warnings + source/confidence, cross-check against source imagery before committing the report.
- report.py writing to the real docs/VALIDATION_REPORT.md during tests would pollute the repo. Mitigation: tests write to a tmp path; the committed report is generated only on a real full run.

### Manual setup (human-gated)

- Pre-pick the 15 stratified addresses (5 simple / 5 moderate / 5 complex; 3 each in Lincoln NE, Chicago, a Sun Belt metro, a Pacific NW metro, Northeast) and verify each has 3DEP coverage via https://apps.nationalmap.gov/lidar-explorer/; record the expected WESM work-unit name.
- Purchase one EagleView Premium report (~$80, 1-2 business days) on a 3DEP-covered roof; hand-transcribe total area, per-facet areas, pitches into ground_truth.yaml; commit the PDF only if licensing permits.
- Tape-measure one simple roof (own/friend's house) with a hand-drawn facet sketch; record areas + pitches in ground_truth.yaml.
- Pull one county-assessor record (free online); document the URL + extracted square footage + caveats (planimetric vs pitched).
- Pull + hand-label the feature-detection dataset: run pull_tiles against NAIP for the chosen roofs, then hand-label every tile's feature bboxes (chimney/vent/skylight/dormer/satellite_dish) per LABELING_PROTOCOL.md, including >=1 true-negative tile (~4-6h human effort).
- Run the full harness at least once before the demo with live Modal + OpenRouter credentials (~$5) to populate docs/VALIDATION_REPORT.md with current numbers; commit the report.
- Provision/confirm a dedicated harness Postgres DB so runner-created Job/Measurement rows do not pollute the dev/test DB.

### Open questions for the human

- Does MeasurementOrchestrator expose a way to force the LiDAR-missing / satellite-only fallback path? ADR-017's fallback-consistency metric depends on it. If not, who owns adding it, or is the fallback table scoped out as a documented gap?
- Through the OpenRouter FeatureDetector backend, which specific model slugs are reachable for the candidate sweep (ADR-006 needs >1)? Default is google/gemini-2.5-flash; what is the second+ candidate?
- How does the eval feed a tile image to detect(image_tile_url:)? Must we mint a signed Spaces URL for each committed tile, or can the imagery host allowlist accept a local/test URL for the eval? (detect takes a URL, not an array.)
- Which DB should the runner write to so it does not violate the CLAUDE.md 'no committed rows in the dev/test DB' rule — a throwaway harness DB, or a rolled-back transaction (which conflicts with persisting Measurements across orchestrator calls)?
- Model-selection metric: unweighted F1 (proposed v1) vs recall-weighted (a missed rooftop feature is arguably worse than a false positive for the report). Confirm v1 = unweighted F1, note recall-weighting as v2.
- Should docs/VALIDATION_REPORT.md be overwritten each run or archived by timestamp (docs/validation-reports/<date>.md) for historical comparison?
- EagleView PDF redistribution licensing — can the PDF be committed to the repo, or must ground_truth.yaml reference it by note only?
