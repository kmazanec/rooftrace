# Feature: Stretch — Server-side AR overlay on captured photos

**ID:** F-18 · **Roadmap piece:** F-18 · **Status:** Done (merged to main · iteration `wave5-stretches`) · **Type:** Stretch

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

- [x] **(BARRIER) Amend the pipeline contract** into the merged **0.4.0**
  bump (coordinate with F-17): `ProjectPhotoRequest` += `world_mesh_ref`,
  `arkit_to_utm[16]`, `utm_epsg`, `features`, `pose_confidence`;
  `ProjectPhotoResponse` → `composite_ref`, `overlay_svg_ref`,
  `pose_confidence`, `occluded_facet_ids`; `FuseCaptureResponse` +=
  `arkit_to_utm[16]`, `utm_epsg`. (Landed in the frozen-contract commit; this
  workstream consumed it unchanged.)
- [x] **(BARRIER) Persist the ICP transform out of fusion:**
  `fused_provenance` += `fusion_arkit_to_utm_4x4` + `fusion_utm_epsg` from
  the amended `FuseCaptureResponse`. (Provenance plumbing landed in the freeze;
  this workstream made `fuse-capture` actually RETURN the solved 4x4 + epsg.)
- [x] **(BARRIER) `ProjectedOverlay` migration + model** (UUID PK;
  `capture_id` FK + **unique** index; `composite_ref`, `overlay_svg_ref`,
  `pose_confidence`, `low_pose_confidence`, `occluded_facet_ids` jsonb).
  `Capture has_one :projected_overlay`. (Landed in the freeze.)
- [x] **Projection math** `sidecar/app/render/photo_projection.py`, test-first:
  `project_facets(facets, intrinsics_3x3, world_to_camera_4x4)` → 2D polygons,
  ±2px against a synthetic known-camera fixture. + `facets_wgs84_to_arkit`
  frame bridge with an exact round-trip test.
- [x] **trimesh ray-cast occlusion:** `photo_occlusion.py` loads
  `arkit_mesh.obj` faces-aware via trimesh; ray from camera origin per facet
  sample; nearer-mesh-hit → partial(dashed/dimmed); fully occluded → omitted.
  No pyrender/OSMesa (rtree-backed RayMeshIntersector).
- [x] **SVG overlay + composite** `photo_overlay.py`: facet polygons 2px stroke
  colored by pitch (viewer gray ramp), 12pt centroid labels, partial dashed +
  dimmed; rasterize over source RGB at source res via Pillow (no cairo);
  EXIF-free fixed encode for determinism. (Feature pins deferred — see notes.)
- [x] **Sidecar `project-photo` router** (`_major()` 409, 422 validation;
  `get_bytes` photo + mesh; bridge facets WGS84→UTM→arkit-local; project +
  occlude + composite; `put_bytes` to `artifacts/<job_id>/projected/`); gated by
  `PROJECT_PHOTO_LIVE` (hermetic placeholder otherwise).
- [x] **Pose-confidence gate:** **Rails is the single authority**
  (`ProjectionPoseConfidence`) — score from `icp_rmse_m` + an extrinsics sanity
  check (finite, orthonormal-ish R, plausible t), monotonic-decreasing in
  `icp_rmse_m`. Threshold default **0.7** via **`PROJECTION_POSE_CONFIDENCE_MIN`**;
  below → no sidecar call, persist a `low_pose_confidence` overlay. The sidecar
  may only *narrow* the value (orchestrator takes the min).
- [x] **`SidecarClient#project_photo(...)`** + `PROJECT_PHOTO_TIMEOUT_SECONDS`.
  (Landed in the freeze; consumed unchanged.)
- [x] **`ProjectionJob`** (FusionJob pattern: `retry_on`, `MAX_ATTEMPTS`,
  `queue_as :default`, **never touches Job status**, idempotent on existing
  overlays); per-photo loop in `ProjectionOrchestrator`; broadcasts
  `[job, :projection_status]`.
- [x] **Chain after fusion:** one line at the end of
  `FusionOrchestrator#call` — `ProjectionJob.perform_later(@job.id)` — only on a
  converged fusion (failed fusion has no solved transform).
- [x] **Viewer "On-Site Visualization"** surface: serializer +
  `ViewerPayload.on_site_visualizations` (landed in freeze); swipeable
  `OnSiteGallery` in `RoofViewer.tsx`; facet↔gallery cross-highlight at the
  index level (map facet click activates the gallery + badge; gallery selection
  bubbles up). Deeper occlusion-aware cross-highlight descoped — see notes.
- [x] **PDF surface** fills the evidence seam: `ReportPdf#evidence_photos_for`
  prefers `artifacts/<job_id>/projected/` composites (most pose-confident first,
  capped 4). No change to `_evidence_photos.html.erb`. (Builder landed in the
  freeze; this workstream added its regression coverage.)
- [x] **JSON export** (additive **1.1.0**): `on_site_visualizations` array;
  schema/const/changelog/drift landed in freeze; `JobVisualizations` injects the
  signed-URL array into both export routes (ADR-015 auth + public parity).
- [x] **Commit deterministic fixture composites** to
  `spec/fixtures/projections/` (synthetic_house → SVG primary artifact +
  tolerance PNG; CPU-only; regenerable via the committed generator).
- [x] **Deps + boot check:** added `trimesh` + `svgwrite` + `rtree` to
  `sidecar/pyproject.toml` (not pyrender); `boot_checks.py` `project_photo`
  `_StageCheck` verifies importability when `PROJECT_PHOTO_LIVE=1`.

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

### What landed and why

- **Live render is flag-gated (`PROJECT_PHOTO_LIVE=1`), placeholder otherwise.**
  Mirrors `RENDER_IMAGES_LIVE` / `FUSE_CAPTURE_LIVE`: the hermetic default writes
  a 1x1 placeholder so the contract round-trip + storage convention are exercised
  without Pillow/trimesh work, and the boot check fails fast in prod if the live
  deps aren't importable. The real render runs under the flag and in live tests.

- **`arkit_to_utm` + `utm_epsg` are REQUIRED to project; there is no in-stage ICP
  recompute.** The plan floated "recompute from mesh+lidar" as a fallback, but the
  frozen `ProjectPhotoRequest` carries no LiDAR ref - the sidecar can't re-run
  ICP. Resolution (the panel's preferred path anyway): Rails persists the solved
  transform to `Measurement.provenance` at fusion time, so a converged job always
  has it; a request lacking it 422s deterministically. `world_mesh_ref` is used
  only for occlusion.

- **Occlusion uses trimesh's `RayMeshIntersector` backed by `rtree`** (added to
  deps + boot check). The pure-Python intersector needs an Rtree spatial index;
  rtree ships manylinux/macos wheels, so the path stays CI-friendly with no
  pyrender/OSMesa/pyembree/conda. `parse_obj` (fusion) returns verts only, so
  `photo_occlusion.load_world_mesh` loads faces via trimesh.

- **No cairo / native SVG rasterizer.** `composite_png` re-draws the SAME
  primitives the SVG encodes (a tiny format-specific reader over our own
  deterministic output) with Pillow's `ImageDraw`. The SVG is the PRIMARY visual-
  regression artifact (exact text diff); the PNG is a tolerance diff.

- **`pose_confidence` is Rails-authoritative; the sidecar may only narrow it.**
  `ProjectionPoseConfidence` scores from the session `icp_rmse_m` (monotonic) and
  a per-photo extrinsics sanity gate. `ProjectionOrchestrator` persists
  `min(rails_score, sidecar_value)` so the sidecar can lower but never raise it.

- **Feature pins DEFERRED (documented v1 limitation).** The frozen `Feature` $def
  carries only `bbox_norm` (normalized against the SATELLITE tile), not a 3D
  position - there is no way to project a feature into the PHOTO's pinhole frame.
  Drawing them at a guessed location would be a misregistered pin (the exact
  failure the pose gate exists to avoid). Facet overlays are the core deliverable;
  feature pins wait for a contract that carries a feature world position.

- **Facet<->gallery cross-highlight is index-level, not occlusion-aware.** The
  frozen viewer `OnSiteVisualization` type carries no `occluded_facet_ids`, so the
  gallery can't dim the photos that hide a selected facet without a contract
  change. v1 ships the bidirectional index-level highlight (map facet click
  activates the gallery + a badge; gallery selection bubbles up) - the planned
  "designated descope if it overruns."

- **Composite/SVG are exposed in the export; the source photo is not.** The source
  capture photo lives under `uploads/`, which `ArtifactUrlMinter` (artifacts/-
  locked) cannot sign, so `on_site_visualizations[].photo_url` is null (the schema
  permits null). The composite IS the exposed artifact.
