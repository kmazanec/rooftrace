# Feature: Roof outline refinement (SAM2)

**ID:** F-07 · **Roadmap piece:** F-07 · **Status:** Not started

## Description

Refines a building polygon (the MS Footprints prior from F-05) into a
pixel-accurate roof outline using SAM2 zero-shot segmentation on the
NAIP imagery tile, then simplifies via Douglas–Peucker to a clean
vector polygon with a small number of vertices. Per
[ADR-005](../adrs/ADR-005-roof-outline-sam2-with-prior.md), this
unifies the LiDAR and no-LiDAR paths — both produce a refined-from-
imagery polygon used downstream.

SAM2 inference runs on Modal (serverless GPU) per
[ADR-012](../adrs/ADR-012-gpu-inference-modal.md), with a local-CPU
fallback so the demo doesn't die during a Modal outage.

## How it fits the roadmap

Wave 2 — geospatial pipeline track. Parallel with F-05, F-06, F-08, F-09.
Off the critical path (LiDAR F-06 dominates). Unblocks the
orchestrator (F-10).

## Dependencies (must exist before this starts)

- **F-01 Walking skeleton** — deployed stack with sidecar.
- **F-02 Pipeline JSON Schema** — defines the `Polygon` shape.

## Unblocks (what waits on this)

- **F-10 Measurement orchestrator** — consumes the refined polygon.
- **F-08 Plane fit** uses the refined polygon as the planar extent
  cross-check (integration via F-10).

## Acceptance criteria

- Sidecar exposes `POST /pipeline/refine-outline` taking
  `{image_tile_url: string, prior_polygon: GeoJSON, image_geo_bounds:
  [west, south, east, north]}` and returning `{refined_polygon: GeoJSON,
  iou_with_prior: float, source: "sam2", sam2_backend: "modal" | "local"}`
  — schema-validated.
- **Default backend is Modal**; the sidecar's `infer_sam2()` function
  selects based on `SAM2_BACKEND` env var (`modal` | `local`); both
  paths produce equivalent outputs for the same input (verified by a
  parity test).
- **Modal cold-start mitigation:** the sidecar can issue a warm-up
  call at boot or on demand; warm-call latency <2s, cold <30s.
- **Outline refinement quality:** for a fixture corpus of 5 NAIP
  tiles + MS Footprints priors, IoU between the refined polygon and a
  human-traced reference is ≥ 0.85 on 4/5 cases.
- **Douglas–Peucker simplification:** output polygon has ≤30 vertices
  for typical residential roofs; tolerance is configurable and
  documented.
- **Fallback to prior:** if SAM2 inference produces a mask with
  IoU<0.5 vs. the prior (sign of catastrophic leak onto a different
  surface), return the prior unchanged with a warning
  `"sam2_low_confidence"`.
- **CRS:** input bounds in EPSG:4326 (lat/lng); refined polygon
  returned in EPSG:4326 to match input convention; downstream
  callers handle reprojection.
- **Performance:** typical refinement <2s on Modal warm; <10s cold;
  <15s on local CPU fallback.

## Testing requirements

- **Parity test:** Modal backend and local backend produce
  pixel-equivalent masks (within 5% IoU) on the same fixture image
  + prior. Catches model-version drift between the two paths.
- **Refinement quality test:** the 5-tile fixture corpus with
  human-traced references; assert IoU ≥ 0.85 on 4/5.
- **Fallback-to-prior test:** synthetic image with no clear roof
  triggers the IoU<0.5 fallback path with the warning.
- **Performance test:** warm Modal call <2s, asserted in CI against
  a deployed Modal endpoint.
- **Schema validation:** all responses validate.

## Manual setup required

- **Modal account + tokens:** create a Modal account, install
  `modal` CLI, set up `MODAL_TOKEN_ID` / `MODAL_TOKEN_SECRET`.
- **Deploy the SAM2 Modal function** once (`modal deploy
  sidecar/inference/sam2_modal.py`); document the deploy command.
- **Bake SAM2 weights into both Modal image and local sidecar
  image** — pin to a specific checkpoint hash for reproducibility.
  Weights download from Meta's official release; document the URL.
- **Verify SAM2 license** (Apache 2.0 — confirmed at write time;
  re-verify if Meta changes terms).

## Implementation notes (filled in by the building agent)

> The agent implementing this feature records its implementation
> decisions and rationale here as it builds — chosen libraries/patterns
> within the architecture's constraints, trade-offs made, deviations
> from assumptions and why, and anything the next agent or the
> integrator needs to know. This section starts empty and is owned by
> the builder, not the planner. Cross-cutting discoveries that affect
> other features must also be propagated to ROADMAP.md or the
> architecture doc, not just left here.
