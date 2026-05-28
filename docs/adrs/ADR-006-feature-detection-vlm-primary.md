# ADR-006: Detect roof features with a VLM as the starting implementation, behind a swappable interface, with model choice decided by evaluation

**Status:** Accepted · **Date:** 2026-05-27 · **Stretch:** no
**Supersedes:** none · **Superseded by:** none

## Context

The brief asks for automatic detection and positioning of **vents,
chimneys, dormers, skylights, satellite dishes**. This is the
attention-grabbing capability in the demo and one of the two most
load-bearing AI features (the other being measurement itself).

The public-dataset situation is poor for this exact task:

- **DOTA** (aerial object detection) — has buildings but no roof
  features.
- **iSAID, LoveDA** — segmentation datasets, no roof features.
- **xBD** (building damage) — wrong task.
- **CompanyCam's own photo corpus** would be ideal but we don't have it.
- A handful of academic roof-feature datasets exist (RID — Roof
  Information Dataset) but are small and domain-specific.

No published benchmark measures the precise target task — small
rooftop features in nadir satellite imagery at ~30–60 cm GSD — so any
model choice has to be **validated by our own measurement**, not
assumed from general leaderboards.

That means **no realistic path involves training-from-scratch** in 4
days. The path has to be either:

- **Off-the-shelf generative vision** — VLMs that follow natural-language
  prompts and produce structured output.
- **Off-the-shelf foundation models** — zero-shot detectors + segmenters
  + classifiers wired into a pipeline.
- **Fine-tune from pretrained weights** on a tiny hand-labeled set.

CompanyCam's own briefs explicitly encourage **RubyLLM** and an
LLM-call-from-Rails AI architecture. That makes a VLM-based feature
detector culturally aligned: in production they could literally call a
VLM via RubyLLM from a Solid Queue job.

## What the evidence says (and does not say)

We do not have measured precision/recall for any candidate model on
*this* task (small rooftop features, nadir, 30–60 cm GSD); no public
benchmark covers it. What the published literature does establish, on
adjacent overhead-imagery tasks:

- General frontier VLMs (GPT-4o, Gemini, Claude) are **weak at
  producing accurate bounding boxes for overhead small objects**. On
  GEOBench-VLM (ICCV 2025) the best VLM reached only ~0.34
  precision@0.5 on referring-expression grounding (GPT-4o ~0.009).
- On the general GroundingME grounding leaderboard (Dec 2025),
  Gemini-2.5-Flash ranks 6th (~18.7%), behind Qwen3-VL (45.1%) and
  Seed-1.6-Vision (42.6%) — i.e. no current evidence that Gemini Flash
  leads VLMs on precise grounding.
- On remote-sensing visual grounding (DIOR-RSVG), general VLMs score
  ~15–44 Acc@0.5, while a domain-fine-tuned model (GeoGround) reaches
  77.73 — **specialized, domain-trained detectors clearly lead**
  (RT-OVAD 87.7 AP50 / LAE-DINO 85.5 AP50 on DIOR).
- Off-the-shelf open-vocabulary detectors (Grounding DINO, OWLv2)
  transfer **poorly** to aerial imagery zero-shot (OWLv2 best ~27.6%
  F1 with a 69% false-positive rate).
- Coordinate conventions vary by model — e.g. Qwen2.5-VL emits absolute
  pixel coordinates, not normalized — so the output adapter is
  per-model.

Sources: GEOBench-VLM (arXiv 2411.19325, ICCV 2025); GroundingME (arXiv
2512.17495); GeoGround (arXiv 2411.11904); RT-OVAD (arXiv 2408.12246)
and the MDPI Drones 2025 OVAD survey; LAE-80C transfer study (arXiv
2601.22164, preprint); Qwen2.5-VL technical report (arXiv 2502.13923).

The honest reading: the *regime* favors a domain-trained detector for
localization accuracy, but none of these benchmarks is our task, and a
4-day window does not permit training one from scratch. So we ship a
VLM as the **starting implementation** to satisfy the brief, behind an
interface that lets a measured winner replace it — and we stand up an
evaluation suite (see "Consequences for the build") so the production
model is chosen on numbers, not assumption.

## Options considered

**A. VLM as the starting detector**, structured output, light
verification pass on low-confidence detections. Pass the cropped nadir
tile + the roof polygon overlay; prompt for a JSON list of features
with bounding boxes from a fixed vocabulary. For any detection below a
confidence threshold, re-prompt with a tight crop ("is there a
[feature] in this image? yes/no with confidence").
*Tradeoff:* simple, fast to build, aligns with CompanyCam's LLM-first
AI strategy; but published grounding benchmarks show general VLMs
localize overhead small objects poorly, bbox precision is coarse, and
detections are non-deterministic between calls — so its accuracy on
*this* task is unknown until measured.

**B. Grounding DINO + SAM2 + CLIP zero-shot.** Open-vocab detector
finds "small rooftop object" → SAM2 segments → CLIP classifies each
crop against the label vocabulary.
*Tradeoff:* deterministic, precise pixel masks; three models in series
adds latency and failure modes, and published results show generic
open-vocab detectors transfer poorly to aerial imagery zero-shot.

**C. Fine-tune a detector (e.g. YOLO / a DOTA- or LAE-trained model) on
hand-labeled rooftop-feature crops.** Highest accuracy ceiling — the
literature shows domain-trained aerial detectors lead — and the
defensible "we trained for the task" story.
*Tradeoff:* requires labeling effort and training infra; outcome
variance is high on a small dataset; not feasible to complete inside
the 4-day v1 window, but the strongest production-accuracy path.

**D. Punt — defer to ground-perspective photos** (CompanyCam's existing
crew photos as the future input).
*Tradeoff:* honestly framed as a stretch / v2, but cuts a brief
requirement in v1.

## Decision

Ship **a VLM as the v1 starting implementation** (using
structured-output JSON, with the roof polygon overlaid on the input
tile to focus the model), behind a **`FeatureDetector` interface** so
the model is a swappable, env-selectable choice rather than an
architectural commitment. Detections below a configurable confidence
threshold (default ~0.6) trigger a **verification pass**: re-prompt
with a tight crop around the bbox asking for a yes/no with confidence.
Verified-positive detections render at full opacity; unverified
detections render dimmed with a "verify" badge.

**Which specific model is used in production is an open question to be
decided by the evaluation suite (Option C remains the production-
accuracy upgrade path), not by this ADR.** Until that evaluation
exists, no claim that any particular model is "best" for this task is
warranted.

## Rationale

This is the path that ships multi-class rooftop-feature detection
within the 4-day window, and it does so in a way that **mirrors how
CompanyCam itself would build this in production**: a RubyLLM call from
a Solid Queue job, a structured-output schema, and confidence-aware UX.

The verification pass earns the "honest uncertainty" UX framing from
the COMPANY.md design contract. Instead of declaring "AI says 3 vents,"
the UI shows: "**3 vents detected** · 2 high-confidence · 1 pending
verify (tap to confirm)." That is the register CompanyCam uses in its
own product copy.

The commitment is the **interface, not the model**. The published
evidence (above) says a domain-trained detector is the likely accuracy
winner and that general VLMs localize overhead objects weakly — so the
design must let us measure candidates (different VLMs, an open-vocab
pipeline, a fine-tuned detector) and swap in whichever wins on our own
labeled set, behind the same JSON contract. That is exactly what the
`FeatureDetector` interface plus the evaluation suite provide.

## Tradeoffs & risks

- **Localization accuracy is unproven for this task.** Published
  benchmarks show general VLMs localize overhead small objects poorly;
  whether the chosen model is adequate here is unknown until measured.
  Mitigation: the evaluation suite (below) is a hard dependency for any
  production accuracy claim; the interface lets us replace the model.
- **Non-determinism.** Same image → slightly different detections call
  to call. Mitigation: deterministic decoding where supported; cache
  responses by input-image hash; the verification pass filters the most
  flaky positives.
- **Bbox precision is coarse.** VLM-returned boxes are imprecise.
  Mitigation: the report uses the bbox as a *positioning hint*, not a
  measurement of feature size; rendering shows a marker at the bbox
  center with a label, not a tight outline.
- **Small features fail at low GSD.** A small vent against 60 cm
  imagery is borderline. Mitigation: prefer higher-resolution imagery
  where available; for the demo, hand-pick addresses with visible
  features; document the GSD dependency in the writeup and measure it
  in the eval suite.
- **Hallucinated features.** Mitigation: the verification pass catches
  obvious ones; the report always shows the crop alongside the claim so
  the user can sanity-check visually.
- **Per-model output conventions.** Coordinate formats differ across
  VLMs (normalized vs absolute pixel). Mitigation: the adapter behind
  the `FeatureDetector` interface normalizes per model.
- **Vendor dependency.** Mitigation: the interface supports multiple
  implementations selectable by env var; no model is hard-wired.
- **TOS / data handling.** Sending property imagery to a third-party
  LLM has privacy implications at production scale. Mitigation: noted
  as a future ADR for production deployment; the demo is single-tenant.

## Consequences for the build

- **`FeatureDetector` is a module interface** with at least one VLM
  implementation behind it, selected by env var. The pipeline calls
  `detector.detect(image_tile, roof_polygon)` and receives
  `list[Detection]` with fields `(label, bbox_norm, confidence,
  verified, raw_response)`.
- **An evaluation suite is a required deliverable, not optional.** It
  needs: **a pulled-and-hand-labeled dataset of roof image tiles**
  sourced through the production imagery provider (ADR-002) at the
  target GSD — diverse over roof complexity and feature presence,
  including true-negative roofs — labeled with the fixed vocabulary and
  committed with its provenance manifest; per-class precision / recall
  and bounding-box IoU as the metrics; and a harness that runs the
  *same* eval across each candidate model behind the interface so the
  production model is chosen by measured accuracy. Acquiring and
  labeling that dataset is itself part of the eval work, not an assumed
  precondition. This extends the
  accuracy-validation work in [ADR-017](ADR-017-accuracy-validation-harness.md)
  (which today covers roof-*area* measurement only) to feature
  detection. No model is declared production-default until it wins this
  eval.
- **Prompt + JSON schema live in version control** (no inline prompts)
  with a deterministic fixture image for regression tests.
- **Verification pass** is wired into the same module: detections below
  threshold get tight-cropped and re-prompted; results merged.
- **UI rendering** uses one of three states per detection: `verified`
  (full opacity, no badge), `pending` (dimmed, "verify" badge),
  `rejected` (filtered out, not shown). Names appear in the JSON export
  so downstream consumers can apply their own thresholds.
- **PDF report** includes a small features table with confidence and
  source method per detection, consistent with the honest-uncertainty
  UX.
- **A fine-tuned domain detector (Option C) is the documented
  production-accuracy upgrade path**, gated on the eval suite showing
  it wins.
