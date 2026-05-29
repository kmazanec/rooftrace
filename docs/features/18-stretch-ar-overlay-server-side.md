# Feature: Stretch — Server-side AR overlay on captured photos

**ID:** F-18 · **Roadmap piece:** F-18 · **Status:** Planned (iteration `wave5-stretches`) · **Type:** Stretch

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

## Build plan (approved)

> Planned by the plan-iteration step for the `wave5-stretches` iteration
> (escalated to a 3-draft panel — math-first / contract-first / risk-first —
> then synthesized). Model tier: **opus** (cross-language projection math +
> a multi-entity contract amendment touching both clients + fusion + three
> coupled surfaces). Shared contracts are frozen in `docs/BUILD-PLAN.md`.

**Approach:** A new sidecar projection stage projects measured facets onto
each captured iOS photo (pinhole math), marks mesh-occluded segments via
**trimesh ray-cast (not pyrender — CI-friendly)**, composites an SVG
overlay onto the source RGB, and uploads composite PNG + overlay SVG to
`artifacts/<job_id>/projected/`. A Rails `ProjectionJob` — chained off
`FusionOrchestrator` after the fused measurement commits — calls the stage
per photo and persists `ProjectedOverlay` rows. Composites surface in the
web viewer ("On-Site Visualization" gallery), F-17's PDF evidence seam,
and an additive `on_site_visualizations` JSON-export array.

**Coordinate-frame decision (the load-bearing call, confirmed by the
panel):** project in **`arkit_session_local`** — per-photo
`world_to_camera` extrinsics and `arkit_mesh.obj` are both native to it, so
neither camera nor mesh is transformed. Facets (WGS84) are brought *in*:
WGS84 → local UTM → (inverse ICP) → arkit-local. The ICP arkit→UTM
transform is computed in `fuse-capture`'s `align_mesh_to_lidar` today but
**trapped — never returned or persisted.** Resolution: persist the 4×4 to
`Measurement.provenance` during fusion (one source of truth); fallback is
recompute-from-mesh+lidar inside `project-photo` for measurements predating
the field.

- [ ] **(BARRIER) Amend the pipeline contract** into the merged **0.4.0**
  bump (coordinate with F-17): `ProjectPhotoRequest` += `world_mesh_ref`,
  `arkit_to_utm[16]`, `utm_epsg`, `features`, `pose_confidence`;
  `ProjectPhotoResponse` → `composite_ref`, `overlay_svg_ref`,
  `pose_confidence`, `occluded_facet_ids`; `FuseCaptureResponse` +=
  `arkit_to_utm[16]`, `utm_epsg`. Both clients move together; changelog +
  drift spec.
- [ ] **(BARRIER) Persist the ICP transform out of fusion:**
  `fused_provenance` += `fusion_arkit_to_utm_4x4` + `fusion_utm_epsg` from
  the amended `FuseCaptureResponse`.
- [ ] **(BARRIER) `ProjectedOverlay` migration + model** (UUID PK;
  `capture_id` FK + **unique** index; `composite_ref`, `overlay_svg_ref`,
  `pose_confidence`, `low_pose_confidence`, `occluded_facet_ids` jsonb).
  `Capture has_one :projected_overlay`.
- [ ] **Projection math** `sidecar/render/photo_projection.py`, test-first:
  `project_facets(facets_arkit, intrinsics_3x3, world_to_camera_4x4)` →
  2D polygons, ±2px against a synthetic known-camera fixture.
- [ ] **trimesh ray-cast occlusion:** load `arkit_mesh.obj` via trimesh
  (faces-aware — `parse_obj` returns verts only); ray from camera origin
  per facet sample; nearer-mesh-hit → dashed/dimmed; fully occluded →
  omitted. No pyrender/OSMesa.
- [ ] **SVG overlay + composite** via svgwrite + pillow: facet polygons
  2px stroke colored by pitch (reuse viewer pitch colors), 12pt labels at
  centroid, low-confidence dashed; feature pins (F-12 icon set); rasterize
  over source RGB at source res; EXIF-strip + fixed encode for determinism.
- [ ] **Sidecar `project-photo` router** (`@router.post`, `_major()` 409,
  422 validation; `get_bytes` photo + mesh; bring facets
  WGS84→UTM→arkit-local; project + occlude + composite; `put_bytes` to
  `artifacts/<job_id>/projected/`); register in `main.py` with the bearer dep.
- [ ] **Pose-confidence gate:** **Rails is the single authority** —
  computes `pose_confidence` per photo from `icp_rmse_m` (session-level) +
  a per-photo extrinsics sanity check (finite, orthonormal-ish rotation,
  plausible translation), monotonic-decreasing in `icp_rmse_m`. Threshold
  default **0.7** via env var **`PROJECTION_POSE_CONFIDENCE_MIN`**; below →
  no sidecar call, persist a `low_pose_confidence` overlay, surface a
  warning (not a broken overlay). The sidecar may only *narrow* the
  returned value, never raise it.
- [ ] **`SidecarClient#project_photo(...)`** + `PROJECT_PHOTO_TIMEOUT_SECONDS`,
  following `render_images`.
- [ ] **`ProjectionJob`** (FusionJob pattern: `retry_on`, `MAX_ATTEMPTS`,
  `queue_as :default`, **never touches Job status**, idempotent on existing
  overlays); per-photo loop; broadcasts `[job, :projection_status]`.
- [ ] **Chain after fusion:** one line at the end of
  `FusionOrchestrator#call` — `ProjectionJob.perform_later(...)` — safe to
  re-trigger for an already-fused job.
- [ ] **Viewer "On-Site Visualization"** surface (extends F-12):
  serializer + `ViewerPayload.on_site_visualizations`; swipeable gallery in
  `RoofViewer.tsx`; facet↔gallery cross-highlight (**in scope for v1**; the
  designated descope if it overruns).
- [ ] **PDF surface** fills F-17's seam: `ReportPdf` prefers
  `artifacts/<job_id>/projected/` composites (top 1–2 by `pose_confidence`).
  No change to `_evidence_photos.html.erb`.
- [ ] **JSON export** (additive **1.1.0**): `on_site_visualizations`
  array; schema extended + const bumped + changelog + drift spec; auth +
  public routes identical (ADR-015 parity).
- [ ] **Commit deterministic fixture composites** to
  `spec/fixtures/projections/` (synthetic_house session + fixture
  measurement → `ProjectionJob` in local-root mode; CPU-only).
- [ ] **Deps + boot check:** add `trimesh` + `svgwrite` to
  `sidecar/pyproject.toml` (not pyrender); CI geo stack installs them;
  `boot_checks.py` `_StageCheck` verifies importability when the
  project-photo live flag is set.

**Tests:** projection-math (±2px); occlusion (behind-wall → dashed);
pose-confidence (perturbed → no composite + warning); frame-bridging
(known `arkit_to_utm` → expected arkit-local coords); end-to-end fixture
(committed composites + visual regression); performance (8 photos < 30s,
mesh loaded once/job); pipeline 0.4.0 + json_export 1.1.0 drift specs;
viewer gallery + cross-highlight; export parity.

**Risks:** frame-bridging is highest-risk (wrong inverse/UTM order →
plausible-but-misregistered overlay — guard with the synthetic ±2px test
first); the fusion-side transform change must live in the barrier, not the
W-18 worktree; new sidecar deps + CI + boot check (rasterio lesson);
deterministic committed composites (prefer stable SVG as primary
regression artifact + tolerance PNG diff); perf; single-authority
`pose_confidence`; **0.4.0 collision with F-17**.

**Decisions** (resolved by Keith — see
`docs/BUILD-PLAN-wave5-stretches.md` "Resolved decisions"): persist
`arkit_to_utm` to provenance during fusion (recompute is fallback only);
SVG as primary visual-regression artifact + tolerance PNG diff;
`pose_confidence` Rails-authoritative, default `0.7` via
`PROJECTION_POSE_CONFIDENCE_MIN`; facet↔gallery cross-highlight in v1 scope.

## Implementation notes (filled in by the building agent)

> The agent implementing this feature records its implementation
> decisions and rationale here as it builds — chosen libraries/patterns
> within the architecture's constraints, trade-offs made, deviations
> from assumptions and why, and anything the next agent or the
> integrator needs to know. This section starts empty and is owned by
> the builder, not the planner. Cross-cutting discoveries that affect
> other features must also be propagated to ROADMAP.md or the
> architecture doc, not just left here.
