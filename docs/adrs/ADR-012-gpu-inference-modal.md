# ADR-012: Use Modal for serverless GPU inference (SAM2 + heavy geometric jobs)

**Status:** Accepted · **Date:** 2026-05-27 · **Stretch:** no
**Supersedes:** none · **Superseded by:** none

## Context

The pipeline has GPU-dependent and CPU-dependent stages:

- **GPU-bound:** SAM2 inference (ADR-005) — wants ~hundreds of ms on
  a modest GPU, runs to several seconds on CPU. Per-job cold-start of
  the model weights matters.
- **CPU-bound:** PDAL pipelines (ADR-003), Shapely arithmetic (ADR-004),
  RANSAC plane fitting, ICP alignment of ARKit meshes (ADR-007).
  These run fine on the droplet's CPU.
- **API-bound:** VLM feature detection (ADR-006) — remote API call,
  no local hardware needed.

The droplet (ADR-011) is CPU-only and that's intentional — GPU droplets
on DO are full provisioned instances ($0.76–$7.99/GPU-hr on-demand per
their current pricing) charged whether or not work is in flight. For a
4-day demo with bursty job traffic and long idle periods, a constantly-
running GPU droplet is the wrong economic shape.

The right shape is **serverless GPU**: pay per second of inference, no
idle cost. Modal is the dominant Python-native answer.

## Options considered

**A. Modal** for SAM2 inference. Python decorator-defined function;
deploys a containerized GPU function; cold-start ~30s, warm-start
sub-second; pay per second of execution.
*Tradeoff:* third-party vendor, separate billing surface; the cleanest
ergonomics for a Python sidecar that needs occasional GPU work.

**B. DigitalOcean GPU droplet** running SAM2 as a persistent service.
*Tradeoff:* same-provider co-location, but constantly-billed even
when idle; provisioning time non-trivial; doesn't match bursty job
traffic. Right answer at 24/7 scale, wrong answer for a demo.

**C. Replicate.** Easy on-ramp, model marketplace.
*Tradeoff:* per-call overhead (~10s) adds latency to every job;
better for shared/public models; less ergonomic for our private
SAM2 use case.

**D. RunPod / Beam / Cerebrium / Spheron** — Modal alternatives.
*Tradeoff:* RunPod is the closest competitor with strong cold-start
numbers; we'd pick it over Modal if cost was the deciding factor.
At v1 volumes the cost delta is irrelevant; Modal's ergonomics and
docs are slightly better for a 4-day build.

**E. Local CPU SAM2** in the Python sidecar on the droplet — skip GPU
entirely.
*Tradeoff:* SAM2 on CPU is ~5–10 seconds per inference; acceptable
for a slow demo, not great for the <5 min latency budget once you
sum with other stages. Worth keeping as a *fallback* but not the
primary plan.

## Decision

**A — Modal for SAM2 inference**, called from the Python sidecar
(ADR-008). The sidecar uses Modal's Python SDK; the function
definition lives in `sidecar/inference/sam2_modal.py` and is
deployed to Modal once per release.

**Fallback path:** if Modal is unavailable (outage, billing issue,
demo network), the sidecar falls back to local CPU SAM2. This is a
runtime config flag; the SAM2 model weights are baked into the
sidecar Docker image so the fallback works without external
dependencies.

**Migration path** (documented, not built): a DO GPU droplet
running SAM2 as a persistent service becomes the right answer when
sustained traffic justifies it — single-provider, lower egress, no
cold start.

## Rationale

The pipeline's GPU usage is bursty by nature: one SAM2 inference per
job, jobs arrive sporadically, idle periods dwarf busy periods. Modal
matches that shape — pay only for the inference seconds, no
provisioning, no idle cost. For the take-home and any reasonable v1
pilot, this is order-of-magnitude cheaper than a provisioned GPU.

Modal's Python-native decorator API means the sidecar (ADR-008) calls
SAM2 in roughly the same lines of code it would call a local
function, with Modal handling Docker packaging, GPU scheduling, and
cold-start optimization transparently. That keeps the sidecar's code
clean and the GPU concern correctly abstracted away.

The local-CPU fallback exists because **demo gods are real**: if
Modal has an outage during the demo, the system degrades to slower-
but-still-working rather than failing outright. The CTO will recognize
this as production-mindset.

The DO-GPU migration path is the right answer eventually, and naming
it is what makes "Modal for now" defensible against "why not stay on
DO?" The answer: "Right answer when sustained traffic crosses the
threshold where idle cost beats serverless overhead — for v1 it
doesn't. The seam is the inference module; we swap it in 50 lines."

## Tradeoffs & risks

- **Cold start ~30s on Modal's first invocation per warm period.**
  Mitigation: a warm-up call at app boot for demo runs; keep-warm
  config for periods of expected demo activity.
- **Vendor dependency.** Mitigation: local-CPU fallback;
  abstracted `Sam2Inference` interface in the sidecar so swapping to
  RunPod / DO-GPU / self-hosted is a class swap.
- **Billing surface.** Mitigation: at v1 volume (demo + a few
  dozen test jobs/day), expected monthly cost is <$10; budget alert
  configured.
- **Network egress from Modal back to the droplet.** Mitigation:
  the SAM2 response is a mask + metadata, low MB; not a cost driver.
- **Model weights versioning.** Mitigation: pin SAM2 weights by
  checkpoint hash in both the Modal function image and the local
  fallback; ensure parity.

## Consequences for the build

- **`sidecar/inference/sam2_modal.py`** defines a Modal `@app.function`
  for SAM2 inference. Modal-deployed once per release; the sidecar
  invokes it as a Python call.
- **`sidecar/inference/sam2_local.py`** wraps the same SAM2 model
  for local CPU execution; same input/output contract.
- **`sidecar/inference/__init__.py`** exposes a single `infer_sam2(...)`
  function that selects Modal or local based on `SAM2_BACKEND` env
  var (`modal` | `local`).
- **`MODAL_TOKEN_ID`, `MODAL_TOKEN_SECRET`** env vars consumed by
  the sidecar; provisioned via Kamal secrets.
- **No GPU on the droplet itself** (per ADR-011). The host stays
  pure CPU.
- **Deployment of the Modal function** is a separate command
  (`modal deploy`) run from the developer's machine; CI hook is a
  v2 concern.
- **Cost monitor:** weekly check on Modal billing dashboard during
  the demo window; budget alert set.
- **Migration path (documented, not built):** when sustained
  inference volume crosses ~100 jobs/hour, provision a DO GPU
  droplet, deploy a persistent SAM2 service on it, set
  `SAM2_BACKEND=do_gpu` in the sidecar.
