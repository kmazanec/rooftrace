# ADR-005: Refine the roof outline with SAM2 zero-shot using the MS Building Footprint as a mask prior

**Status:** Accepted · **Date:** 2026-05-27 · **Stretch:** no
**Supersedes:** none · **Superseded by:** none

## Context

The pipeline has two raw polygon sources for the roof outline:

1. **MS Building Footprints** (ADR-004) — ML-derived from Bing imagery,
   ~80% IoU with manual labels typical. Good prior, occasional artifacts.
2. **The LiDAR point cloud** (ADR-003) — convex hull / alpha shape of
   the class-6 building points gives an outline, but it's noisy at the
   eaves where LiDAR returns drop off, and unavailable in the fallback
   (no-LiDAR) path.

Neither alone is a defensible measurement outline. We need a refinement
pass that:

- Tightens the polygon to **actual roof pixels in the NAIP nadir
  imagery** (so we measure the roof, not the shadow or the neighbor's
  driveway),
- Works **whether or not LiDAR is available** (we want one outline
  algorithm across both paths in ADR-001),
- Doesn't require training data (we don't have any),
- Runs in well under a minute per address.

## Options considered

**A. SAM2 zero-shot, MS footprint as mask/box prior.** Pass the cropped
NAIP tile to SAM2 with the MS Building Footprints polygon as a mask
prompt (or its bounding box as a box prompt). SAM2 refines to the actual
roof pixels. Then run **Douglas–Peucker** simplification on the
resulting mask boundary to get a clean vector polygon with a small
number of vertices.
*Tradeoff:* SAM2 occasionally bleeds onto shadowed walls or onto the
ground when there's no clear contrast; the MS prior is what stops it
wandering. One model, one inference, no training.

**B. Grounding DINO → SAM2.** Text-prompt Grounding DINO with
"roof of a house, top-down view" to localize, then feed the resulting
box to SAM2.
*Tradeoff:* better localization on busy scenes (commercial lots, dense
suburban with many adjacent roofs), but it's a second model in series
— more latency, more failure modes. We already have a strong
localization prior (the MS footprint) so the DINO step is redundant
99% of the time.

**C. Trust MS Building Footprints + Douglas–Peucker directly.**
Skip SAM2; simplify the MS polygon and ship it.
*Tradeoff:* fastest, simplest. The 20% of cases where MS is off — eaves
overhang misaligned, merged with adjacent building, partial detection
— get bad measurements that we can't easily catch without a vision pass.

**D. Pretrained roof-segmentation model** (RoofN3D / Inria UNet weights).
*Tradeoff:* specialized, but most public weights are mediocre and the
training domains (Vienna, Austin, Christchurch) don't generalize cleanly
to nationwide US suburban housing.

## Decision

**A. SAM2 zero-shot with MS Building Footprints as the mask prior, then
Douglas–Peucker simplification.** If SAM2 zero-shot proves unreliable
during accuracy testing (Round 5), upgrade to (B) with Grounding DINO
in front; this is a swap-in within the same module boundary.

## Rationale

SAM2 is the single most-validated, zero-shot, license-clean segmentation
model available right now (Meta, Apache 2.0). It is *designed* to accept
a prior and refine — which is exactly the shape of our problem (we have
a decent polygon, we want a better one). Using the MS footprint as the
prompt prevents the most common failure mode (segment leaks onto wall,
shadow, or driveway) without us writing any roof-specific logic.

This also unifies the LiDAR and no-LiDAR paths from ADR-001: both paths
end up with a refined-from-imagery roof polygon, and on the LiDAR path
we then *cross-check* the polygon against the LiDAR convex hull and flag
disagreements rather than picking arbitrarily. The CTO defense is:
**"the outline is grounded in pixels; the pitch and area are grounded
in geometry (where LiDAR exists) or inference (where it doesn't); we
tell the user which."**

Douglas–Peucker simplification matters because the report needs to show
*roof facets* (planar regions) with vertex coordinates an adjuster can
sanity-check — a pixel-perfect 5,000-vertex mask boundary isn't a
defensible roof diagram, a 12-vertex simplified polygon is.

## Tradeoffs & risks

- **SAM2 still leaks** on roofs whose color matches the surroundings
  (gray gravel roofs on gray asphalt parking lots; white membrane roofs
  in snow). Mitigation: keep the MS prior weight high; use the LiDAR
  hull as a sanity check on the LiDAR path; flag low-IoU
  (LiDAR-hull vs SAM2-mask) cases as "verify."
- **Latency.** SAM2 inference is ~hundreds of ms on GPU, several seconds
  on CPU. Mitigation: GPU inference is part of the orchestration plan
  (Round 4 ADR); on the demo path total is well under the 5-min budget.
- **Polygon simplification tolerance is a tuning knob.** Too aggressive
  → square boxes that miss real corners; too lax → noisy polygons.
  Default to a tolerance that targets ~10–30 vertices for typical
  residential roofs; expose as a config.
- **The fix path to upgrade to Option B is one module swap.** Don't
  rationalize it as "we'll add Grounding DINO later" if the simpler
  approach is good enough — verify with the accuracy harness.

## Consequences for the build

- **One module — `roof_outline.refine(image_tile, prior_polygon) →
  refined_polygon`** — encapsulates SAM2 inference + simplification.
  Imagery-only path and LiDAR path both call into it identically.
- **SAM2 dependency:** Meta `sam2` (Apache 2.0) Python package; weights
  cached locally. GPU recommended; CPU acceptable for low-volume.
- **Cross-check (LiDAR path only):** compute `iou(refined_polygon,
  convex_hull(lidar_building_points))`; flag jobs where IoU < 0.85 with
  a `polygon_disagreement` warning in the result.
- **Vertex output** is normalized to the local UTM projected CRS (per
  the CRS discipline from ADR-003/ADR-004), not pixel coordinates.
- **No Grounding DINO in v1.** Module boundary preserves the option to
  add it later behind the same interface.
