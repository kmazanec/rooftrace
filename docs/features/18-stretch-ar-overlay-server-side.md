# Feature: Stretch — Server-side AR overlay on captured photos

**ID:** F-18 · **Roadmap piece:** F-18 · **Status:** Not started · **Type:** Stretch

## Description

Projects the pipeline's roof facets back onto each photo from the
iOS capture session using standard pinhole-camera math + z-buffer
occlusion against the ARKit world-mesh. The result: one composite
image per captured photo (the original RGB + an SVG facet-overlay
layer with facet outlines colored by pitch, labels for area, and
feature pins). Per
[ADR-019](../adrs/ADR-019-stretch-ar-overlay-on-captured-photo.md),
this is **AR-as-output** (the server projects, the user sees), not
AR-as-input (live AR capture).

The demo "magic moment": *"Here's a photo your crew took yesterday —
and here are our measurements, drawn on top of it."* Composite
images surface in the web viewer (F-12) as a new "On-Site
Visualization" section and in the PDF (F-17) as the evidence-photo
block.

## How it fits the roadmap

Wave 5 — second stretch. **The final node on the critical path:
F-01 → F-02 → F-06 → F-10 → F-16 → F-18.** Depends on both the
orchestrator (F-10, for facet geometry) and iOS fusion (F-16, for
the fused mesh + photo poses).

## Dependencies (must exist before this starts)

- **F-10 Measurement orchestrator** — produces the facets to
  project.
- **F-16 iOS capture ingest + ICP fusion** — produces the
  globally-aligned ARKit mesh + per-photo poses needed for
  projection.

## Unblocks (what waits on this)

- **None** — terminal stretch and final demo deliverable.

## Acceptance criteria

- **Sidecar endpoint:** `POST /pipeline/project-photo` taking
  `{photo_url, camera_pose, intrinsics, facet_set_id, world_mesh_url}`
  and returning `{composite_image_url, overlay_svg_url,
  pose_confidence}`. Schema-validated.
- **Math correctness:**
  - Pinhole-camera projection using EXIF-derived intrinsics
    (focal length, sensor dimensions, principal point if available;
    fallback to defaults for the device model).
  - Extrinsics from the photo's ICP-aligned pose (from F-16's
    fused output).
  - For each facet: project its 3D vertices into the photo's
    image plane; emit an SVG polygon overlay with the same
    confidence-aware styling (color encodes pitch, low-confidence
    facets dashed).
  - **Z-buffer occlusion:** facets partially occluded by the
    ARKit world-mesh from the photo's viewpoint render dimmed/
    dashed; fully-occluded facets are omitted from that photo.
- **Composite rendering:** the output PNG is the original RGB at
  source resolution + a semi-transparent SVG overlay rasterized on
  top; facet outlines are 2 px stroke; labels are 12 pt sans
  positioned at the facet centroid.
- **Feature pin overlay:** detected features with positions that
  project into the photo's frame render as small icon pins (using
  the same icon set as the web viewer per F-12).
- **Pose-confidence threshold:** for photos with
  `pose_confidence < 0.7` (configurable), no composite is
  generated; instead the photo is surfaced with a `low_pose_confidence`
  warning in the viewer/PDF rather than a broken overlay.
- **Triggering:** a `ProjectionJob` (Solid Queue) runs
  automatically after F-16's FusionJob completes; processes each
  captured photo; persists `ProjectedOverlay` rows linked to each
  `Capture`.
- **Web viewer surface (extends F-12):** a new "On-Site
  Visualization" section in the report viewer shows a swipeable
  gallery of composite images; clicking a facet in the map
  highlights it in the gallery and vice versa.
- **PDF surface (extends F-17):** 1–2 highest-pose-confidence
  composites replace or augment the raw evidence-photo
  thumbnails.
- **JSON export (extends F-14):** adds
  `on_site_visualizations: [{photo_url, composite_url,
  overlay_svg_url, pose_confidence}]` to the export.
- **Demo fixture:** the F-15 fixture iOS session bundle paired with
  a fixture measurement produces a known good set of composite
  images committed to `spec/fixtures/projections/` for regression
  testing.

## Testing requirements

- **Projection-math test:** synthetic camera (known intrinsics +
  extrinsics) + synthetic mesh; project a known 3D facet; assert
  the resulting 2D bounding box matches the expected pixel
  coordinates within ±2 pixels.
- **Occlusion test:** synthetic scene with one facet behind a
  wall; verify the occluded section renders dashed/omitted.
- **Pose-confidence test:** intentionally-perturbed fixture pose
  triggers `low_pose_confidence` path; no composite generated;
  warning surfaces in the viewer.
- **End-to-end fixture test:** F-15 fixture session + F-10
  measurement → projection job → committed composite images in
  `spec/fixtures/projections/`; visual regression diff catches
  regressions.
- **Performance test:** projection of 8 photos completes in <30
  seconds.

## Manual setup required

- **Python dependencies in the sidecar:** `pyrender` (z-buffer),
  `trimesh` (mesh ops), `svgwrite` (overlay), `numpy`. All
  pip-installable; document in `sidecar/pyproject.toml`.
- **No new external services** — pure server-side compute.
- **Fixture iOS session** (from F-15) must be available before
  this feature can be acceptance-tested end-to-end.

## Implementation notes (filled in by the building agent)

> The agent implementing this feature records its implementation
> decisions and rationale here as it builds — chosen libraries/patterns
> within the architecture's constraints, trade-offs made, deviations
> from assumptions and why, and anything the next agent or the
> integrator needs to know. This section starts empty and is owned by
> the builder, not the planner. Cross-cutting discoveries that affect
> other features must also be propagated to ROADMAP.md or the
> architecture doc, not just left here.
