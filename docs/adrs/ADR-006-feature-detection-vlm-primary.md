# ADR-006: Detect roof features with a VLM (Gemini Flash) as primary, with light verification

**Status:** Accepted · **Date:** 2026-05-27 · **Stretch:** no
**Supersedes:** none · **Superseded by:** none

## Context

The brief asks for automatic detection and positioning of **vents,
chimneys, dormers, skylights, satellite dishes**. This is the
attention-grabbing capability in the demo and one of the two most
load-bearing AI features (the other being measurement itself).

The public-dataset situation is grim:

- **DOTA** (aerial object detection) — has buildings but no roof
  features.
- **iSAID, LoveDA** — segmentation datasets, no roof features.
- **xBD** (building damage) — wrong task.
- **CompanyCam's own photo corpus** would be ideal but we don't have it.
- A handful of academic roof-feature datasets exist (RID — Roof
  Information Dataset) but are tiny and domain-specific.

That means **no realistic path involves training-from-scratch** in 4
days. The path has to be either:

- **Off-the-shelf generative vision** — VLMs that follow natural-language
  prompts and produce structured output.
- **Off-the-shelf foundation models** — zero-shot detectors + segmenters
  + classifiers wired into a pipeline.
- **Fine-tune from pretrained weights** on a tiny hand-labeled set.

CompanyCam's own briefs explicitly encourage **RubyLLM** and an
LLM-call-from-Rails AI architecture. That makes a VLM-based feature
detector culturally aligned: in production they could literally call
Gemini Flash via RubyLLM from a Sidekiq/Solid Queue job.

## Options considered

**A. VLM as detector (Gemini Flash primary), structured output, light
verification pass on low-confidence detections.** Pass the cropped
nadir tile + the roof polygon overlay; prompt for a JSON list of
features with normalized bounding boxes from a fixed vocabulary. For
any detection below a confidence threshold, re-prompt with a tight
crop ("is there a [feature] in this image? yes/no with confidence").
*Tradeoff:* simple, fast to build, low latency, low cost (Gemini Flash
~$0.0001/image), aligns with CompanyCam's LLM-first AI strategy;
bounding-box precision is coarse (~5–10% of image dim) and detections
are non-deterministic between calls. Accuracy ~70–80% precision /
recall on clear nadir imagery, which is what the brief is asking for.

**B. Grounding DINO + SAM2 + CLIP zero-shot.** Open-vocab detector finds
"small rooftop object" → SAM2 segments → CLIP classifies each crop
against the label vocabulary by text-image similarity.
*Tradeoff:* deterministic, "real ML" framing, precise pixel masks,
three models in series adds latency and failure modes; accuracy on
small aerial features is weaker (~50% P/R) because the models were
trained on natural images, not nadir tiles. Cold-start cost on demo
infra is real.

**C. Fine-tune YOLOv11 on 50–100 hand-labeled NAIP crops.** Highest
ceiling, "I trained a model" defense.
*Tradeoff:* eats a full day of labeling + half-day of training infra;
high outcome variance on a 50–100-sample dataset; one of the two most
direct ways to over-promise and under-deliver on this brief.

**D. Punt — defer to ground-perspective photos** (CompanyCam's existing
crew photos as the future input).
*Tradeoff:* honestly framed as a stretch / v2, but cuts a brief
requirement in v1.

## Decision

**A. Gemini Flash as the primary detector** using structured-output
JSON, with the roof polygon overlaid on the input tile to focus the
model. Detections below a configurable confidence threshold (default
~0.6) trigger a **verification pass**: re-prompt with a tight crop
around the bbox asking for a yes/no with confidence. Verified-positive
detections render at full opacity in the UI; unverified detections
render dimmed with a "verify" badge.

## Rationale

This is the only path that ships multi-class rooftop-feature detection
within the 4-day window at the brief's spec, and it does so in a way
that **mirrors how CompanyCam itself would build this in production**:
RubyLLM call from a Solid Queue job, structured-output schema,
confidence-aware UX. The CTO defense is "this is the same code I'd
write at your company on Monday morning" — which lands harder than a
PyTorch-pretrained pipeline they don't run internally.

The verification pass earns the "honest uncertainty" UX framing from
the COMPANY.md design contract. Instead of declaring "AI says 3 vents,"
the UI shows: "**3 vents detected** · 2 high-confidence · 1 pending
verify (tap to confirm)." That's the register CompanyCam uses in its
own product copy and the register this CTO will recognize as
adult engineering.

Cost matters less than people assume: Gemini Flash at $0.0001/image is
basically free at any plausible early-product scale (1M roofs would
cost ~$100/mo on this line item). Even GPT-4o-class pricing
($0.005/image) is well inside what a $40-per-EagleView-replacement use
case can absorb.

The upgrade path is clean: if Gemini Flash misses small features at
NAIP's 60 cm GSD, switch to GPT-4o or Claude vision behind the same
JSON contract; if VLMs in general turn out to under-perform, the
verification slot becomes a CLIP classifier and the detector swap
becomes a behind-interface change. The module boundary is the model
**interface**, not the model.

## Tradeoffs & risks

- **Non-determinism.** Same image → slightly different detections call
  to call. Mitigation: temperature 0 / deterministic decoding where
  supported; cache responses by input image hash; verification pass
  filters out the most flaky positives.
- **Bbox precision is coarse.** ~5–10% of image dimension is typical
  for VLMs returning normalized bboxes. Mitigation: report uses bbox
  as a *positioning hint*, not a measurement of feature size; rendering
  shows a marker at the bbox center with a label, not a tight outline.
- **Small features fail at low GSD.** A 0.4 m vent against 60 cm
  NAIP is borderline. Mitigation: when NAIP-30 cm is rolled out for
  the region, prefer it; for the demo, hand-pick addresses with
  visible features; document the GSD dependency in the writeup.
- **Hallucinated features** (model returns features that aren't there).
  Mitigation: verification pass catches the obvious ones; report
  always shows the crop alongside the claim so the user can sanity-check
  visually.
- **Vendor dependency.** Gemini Flash specifically. Mitigation:
  abstract behind a `FeatureDetector` interface with at least two
  implementations (Gemini, OpenAI) selectable by env var.
- **TOS / data handling.** Sending property imagery to a third-party
  LLM has privacy implications at production scale (contractors may
  not want addresses leaving their tenant). Mitigation: noted as a
  future ADR for production deployment; the demo is single-tenant.

## Consequences for the build

- **`FeatureDetector` is a module interface** with `GeminiDetector`
  and (optionally) `OpenAIDetector` implementations behind it. The
  pipeline calls `detector.detect(image_tile, roof_polygon)` and
  receives `list[Detection]` with fields `(label, bbox_norm,
  confidence, raw_response)`.
- **Prompt + JSON schema lives in version control** (no inline
  prompts) with a deterministic fixture image for regression tests.
- **Verification pass** is wired into the same module: detections
  below threshold get tight-cropped and re-prompted; results merged.
- **UI rendering** uses one of three states per detection: `verified`
  (full opacity, no badge), `pending` (dimmed, "verify" badge),
  `rejected` (filtered out, not shown). Names appear in the JSON
  export so downstream consumers can apply their own thresholds.
- **PDF report** includes a small features table with confidence and
  source method per detection, consistent with the honest-uncertainty
  UX.
- **No fine-tuned models in v1.** Hand-labeling + training is in the
  writeup roadmap as the "production accuracy upgrade" path.
