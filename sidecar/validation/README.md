# Accuracy validation harness

Defends the +/-3% total-area accuracy claim (ADR-017) with real numbers and
selects the production feature-detection model by measurement (ADR-006). The
output is `docs/VALIDATION_REPORT.md` — a writeup deliverable, not a runtime
artifact.

## Two-process architecture (the language boundary)

The measurement pipeline and the feature detector are **Rails-resident**
(`app/services/measurement_orchestrator.rb`, `app/services/feature_detector.rb`),
so the harness is split across the two-language boundary on purpose:

| Half                | Lives in                              | Produces                          |
| ------------------- | ------------------------------------- | --------------------------------- |
| **Runner** (Ruby)   | `lib/tasks/validation.rake`           | results JSON + `predictions_*.json` |
| **Metrics** (Python)| `sidecar/validation/*.py`             | MAPE/P90/IoU/PR/F1 + the Markdown report |

A Python-only harness could not produce a `Measurement` (the orchestrator
assembles it in Ruby) or run the detector — so the data-producing half MUST be
Ruby. Python owns only pure-function metrics and report generation.

## Layout

```
sidecar/validation/
  metrics.py            pure metric primitives (MAPE, P90, IoU, PR/F1, structural)
  report.py             results JSON -> docs/VALIDATION_REPORT.md
  test_addresses.yaml   15 stratified addresses (5/5/5; human-verified 3DEP)
  ground_truth.yaml     3 controls (EagleView / tape-measure / county assessor)
  results/              runner output: <timestamp>.json (gitignored except .gitkeep)
  fixtures/             frozen WESM index + sample results for tests
  feature_detection/
    pull_tiles.py       fetch satellite tiles via the production imagery path (Mapbox)
    eval_models.py      score candidate models -> eval_results.json
    manifest.json       per-tile provenance
    labels.json         hand-labeled ground truth (fixed vocabulary)
    known_labels.json   frozen mirror of FeatureDetector::KNOWN_LABELS
    LABELING_PROTOCOL.md labeling protocol
```

## Running it

### Fast tests (no network, no creds) — these run in CI

```bash
cd sidecar
uv run pytest tests/test_validation_metrics.py tests/test_validation_config.py \
              tests/test_validation_report.py tests/test_feature_dataset_integrity.py \
              tests/test_eval_models.py -v
```

(The default `uv run pytest` already includes these — they carry no `slow`
marker, so `sidecar_test` in CI covers them.)

### Measurement smoke run (needs a DB + live creds)

```bash
# 3-address smoke; drop ADDRESS_LIMIT for the full 15. INCLUDE_TODO=1 also runs
# placeholder addresses (for plumbing checks before real addresses land).
ADDRESS_LIMIT=3 bin/rails validation:run_measurements
cd sidecar && uv run python -m validation.report   # -> docs/VALIDATION_REPORT.md
```

### Feature-detection model sweep (needs OpenRouter + Spaces creds)

```bash
# Sweeps google/gemini-2.5-flash + qwen/qwen2.5-vl-72b-instruct by default;
# override with CANDIDATE_MODELS=slug,slug.
bin/rails validation:eval_features
cd sidecar && uv run python -m validation.feature_detection.eval_models
# fold the eval into the report:
cd sidecar && uv run python -m validation.report \
  --eval-results validation/feature_detection/eval_results.json
```

Eval tiles are uploaded under the Spaces `cache/` prefix and served to the
detector through a signed URL minted by `ImageryUrlMinter`, so the detector's
host allowlist is satisfied **without widening the SSRF allowlist**.

## Cost & reproducibility

- Full measurement run: ~$5 (Modal + OpenRouter). Smoke (`ADDRESS_LIMIT=3`): ~$1.
- The orchestrator caches by address + input fingerprint, so re-running after a
  metric-code change is cheap (the pipeline is skipped, the results JSON reused).
- The VLM + imagery-fusion steps are non-deterministic; expect total-area numbers
  within measurement noise (typically <1%) across runs on the same pipeline
  version. The report's Methodology section documents this.

## DB hygiene

The runner creates `Job` + `Measurement` rows. Point it at a **dedicated harness
database** (or a disposable dev DB) — NEVER the shared dev/test DB (CLAUDE.md
forbids committed rows leaking into the test DB). The tasks deliberately do not
clean up rows (the cache makes re-runs cheap).

## Manual setup (human-gated, do in this order)

1. **Tape-measure one simple roof** (~1-2 h) — fastest control to collect.
2. **Order one EagleView Premium report** (~$80, 1-2 business days) — start
   early because of delivery time.
3. **Pull + hand-label the feature-detection dataset** (~4-6 h) — run
   `pull_tiles.py`, then label per `feature_detection/LABELING_PROTOCOL.md`.
4. **Pull one county-assessor record** (free, online).
5. **Pre-pick the 15 stratified addresses** and verify 3DEP coverage at
   https://apps.nationalmap.gov/lidar-explorer/; record the WESM work-unit name.
6. **Run the full harness once before the demo** with live creds (~$5) and commit
   `docs/VALIDATION_REPORT.md`.

See `README_GROUND_TRUTH.md` and `feature_detection/LABELING_PROTOCOL.md` for the
collection protocols. `test_addresses.yaml` and `ground_truth.yaml` ship with
`todo: true` placeholders that the config integrity test checks structurally
while exempting from the live-data gates until filled.

## Known gap: fallback-path consistency (deferred)

ADR-017 calls for comparing the satellite-only (Architecture-A) fallback
measurement against the LiDAR primary per address. The orchestrator does not yet
expose a way to force the LiDAR-missing path, so this comparison is **deferred**
and reported as an honest gap in `docs/VALIDATION_REPORT.md` rather than faked.
When a force-fallback flag lands on the orchestrator, the runner will capture
both measurements per address and the report's fallback section will fill in.

## References

- ADR-017 — accuracy validation harness (methodology, metrics, stratification).
- ADR-006 — feature-detection VLM primary (model selection by evaluation).
- ADR-002 — imagery provider (Mapbox; the eval pulls satellite tiles at runtime GSD).
