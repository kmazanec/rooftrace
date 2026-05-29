# ADR-019: Stretch — overlay LiDAR-derived roof facets onto a previously-captured iOS photo

**Status:** Accepted · **Date:** 2026-05-27 · **Stretch:** yes
**Supersedes:** none · **Superseded by:** none

## Context

The brief asks for "AR-guided annotations and measurements." ADR-007
intentionally cut live AR from the iOS capture flow because real AR
UX is a scope item that tends to eat all available time. But the iOS
app *does* capture: photos, ARKit world-anchored mesh, per-frame
depth, GPS, and IMU snapshot per photo. That's everything a server
needs to **project the server-derived roof facets back onto a captured
photo** as a static overlay — i.e., AR-as-output, not AR-as-input.

This is exactly the framing the COMPANY.md stretch list pointed at as
the visual-wow moment: **"Take a photo the crew already took
yesterday → project the LiDAR-derived roof facets onto it in 3D →
contractor can show the homeowner exactly where the work is
happening."** It reuses CompanyCam's existing photo corpus *muscle*
(every workflow starts from a photo) rather than asking the crew to
do new capture work.

Architecturally, this is server-side computer-graphics applied to data
we're already capturing. No new pipeline; no new ML; just camera-
intrinsics math.

## Options considered

**A. Server-side projection of roof facets onto a captured photo,
rendered as a static SVG/PNG overlay.** For each captured photo in
the iOS session, the backend computes the camera pose (using the
ARKit world-mesh + the photo's IMU+GPS), reprojects the geometric
facets into the photo's image plane via standard pinhole-camera
math, draws the facet outlines + labels in SVG over the photo.
Result is one composited image per captured photo, viewable in the
web report and embedded in the PDF (ADR-018).
*Tradeoff:* ~half-day of camera-math work; high visual payoff;
satisfies the "AR-guided annotations" piece of the brief in a
defensible way.

**B. Live AR on the iOS app.** Re-introduce the AR capture flow
that ADR-007 explicitly cut.
*Tradeoff:* over budget; the explicit reason ADR-007 cut it stands.

**C. WebXR overlay** in the browser.
*Tradeoff:* requires the contractor to be back at the site holding
the phone; less useful than "show on any photo, anywhere"; WebXR
device compatibility is uneven.

**D. Skip the AR feature entirely.** Lean on the static measurement
PDF + roof diagram.
*Tradeoff:* leaves "AR-guided annotations" unsatisfied; gives up the
demo's visual wow.

## Decision

**A — server-side projection of roof facets onto captured photos**, with:

- **Input:** for a given job_id with an iOS capture session, take each
  captured photo (RGB), its associated camera pose (derived from the
  ARKit world-mesh registration + photo IMU snapshot), its GPS fix
  for ground-truth scale alignment, and the pipeline's geometric
  facets.
- **Math:** standard pinhole camera projection. Project each facet's
  3D vertices (in the global frame established by ICP-aligning the
  ARKit mesh to public-LiDAR coordinates) into the photo's image
  plane using the photo's camera intrinsics (from iPhone EXIF
  `FocalLengthIn35mmFilm`) and extrinsics (pose). Hidden-surface removal
  via z-buffer ordering against the ARKit world-mesh: facets occluded
  by the mesh from the photo's viewpoint are rendered dimmed/dashed.
- **Output:** for each photo, a composite image (PNG) = the original
  photo + an SVG-over-PNG overlay layer with the facet outlines
  colored by pitch and labeled with area; one optional feature-pin
  overlay (chimney, vent, etc.) at the projected location of each
  feature.
- **Surfaces:** the composited images appear in the web report
  under an "On-Site Visualization" section, and the best 1–2 are
  embedded in the PDF (ADR-018) as the evidence-photo block.

## Rationale

This is the demo's "magic moment" and it falls out of data we're
already capturing for free. The math is standard (pinhole projection +
z-buffer occlusion), implementable in <500 lines of Python
(`pyrender` / `trimesh` / `numpy`). The visual payoff is enormous:
*"Here's a photo your crew took yesterday — and here are our
measurements, drawn on top of it."*

The architectural framing matters too. By making AR an **output**
of the pipeline (projection onto an existing photo), not an **input**
to it (live AR capture), we get the brief's "AR-guided
annotations" deliverable without inheriting the cost of live AR UX
on a 4-day budget. This is exactly the inversion CompanyCam values:
**the work happens server-side where it's debuggable, and the
mobile surface stays a smart camera.**

The CTO defense: *"AR-as-output, not AR-as-input. Every CompanyCam
photo is a potential canvas for server-derived overlays — this is
the spatial substrate that turns the photo archive into a
measurement medium. Roof facets today; damage callouts (per project-2
brief) tomorrow."*

## Tradeoffs & risks

- **Camera pose accuracy.** The projection's visual quality depends
  on accurate camera pose. ARKit pose is ~cm-level over short
  distances; ICP alignment of ARKit-world to public-LiDAR adds
  some error. Mitigation: visible misalignment is itself
  honest-uncertainty UX — small misregistration tells the
  contractor "this is overlay, not perfect"; large misregistration
  triggers a `pose_low_confidence` warning that hides the overlay
  for that photo.
- **Computational cost.** Per-photo projection is fast (~hundreds
  of ms); generating overlays for 8–12 photos per session is
  bounded. Mitigation: render on demand, cache results.
- **Occlusion handling correctness.** Naive z-buffer against the
  ARKit world-mesh may miss occluders the mesh didn't capture
  (e.g., trees). Mitigation: best-effort; non-occluded facets
  always rendered; clear visual distinction (solid vs. dashed)
  between "visible" and "occluded" overlay segments.
- **iOS Session is optional.** Without one, no AR overlay images.
  Mitigation: the feature is presented as additive ("when you've
  done a site visit") not core; the demo includes both an
  iOS-capture path and an address-only path side by side.
- **Demo without a Pro iPhone.** Mitigation: prerecord a fixture
  session bundle from a real Pro iPhone capture before the demo;
  the harness replays it as if it were live.

## Consequences for the build

- **`sidecar/render/photo_projection.py`** owns the math:
  - `project_facets(photo, camera_pose, intrinsics, facets,
    world_mesh) → SVG overlay layer + composited PNG`.
  - Uses `numpy`, `trimesh` for mesh ops, `pyrender` for z-buffer,
    `svgwrite` for the overlay vector layer.
- **Sidecar endpoint:** `POST /pipeline/project-photo` accepts
  `{photo_url, camera_pose, intrinsics, facet_set_id}`, returns
  `{composite_image_url, overlay_svg_url}`. Outputs uploaded to
  `s3://rooftrace-artifacts/<job_id>/projected/`.
- **Rails:** after the capture session is ingested and the
  geometric pipeline completes, a follow-on Solid Queue job calls
  the sidecar's `project-photo` endpoint for each captured photo;
  results persisted as `ProjectedOverlay` rows linked to the
  capture session's photo.
- **Web report viewer (ADR-013)** gains an "On-Site Visualization"
  section showing a swipeable gallery of composited photos.
- **PDF (ADR-018)** embeds the 1–2 highest-confidence projected
  photos in the evidence-photo block (replacing or augmenting
  raw photo thumbnails).
- **JSON export (ADR-015)** adds an `on_site_visualizations`
  array with `{photo_url, composite_url, overlay_svg_url,
  pose_confidence}`.
- **Pose-confidence threshold** is configurable; default ~0.7;
  below threshold, no composite is generated and the warning
  surfaces in the report.
- **Demo fixture:** a pre-recorded iOS capture session bundle
  stored in `spec/fixtures/ios_sessions/` so the AR overlay
  story can be demo'd without a Pro iPhone in hand.

## Amendment: robustness conventions surfaced in review (2026-05-29)

Code review of the implementation surfaced three load-bearing
robustness rules that the per-photo projection loop must follow. They
generalize beyond this ADR (the first two apply to *any* additive
per-item orchestrator, e.g. the ICP `FusionOrchestrator`), so they are
recorded here as decisions rather than left in a PR thread.

- **Per-item failure isolation is mandatory in additive orchestrators.**
  Projection is additive and the job is already `:ready`
  (`ProjectionOrchestrator` never touches job status). Therefore one
  capture's sidecar failure must NOT abort the whole loop: each
  `project_one` is wrapped in a per-capture rescue that persists a
  `low_pose_confidence` (failed) overlay for that capture and continues,
  so a single corrupt photo can't starve every later capture's overlay
  or skip the completion broadcast. Re-raise (to let the bounded
  `ProjectionJob` retry run again) ONLY when every failure was transient
  and none succeeded — a permanent 4xx (e.g. an unreadable photo) does
  not re-raise, because a retry can't fix it and must not clobber the
  overlays that did persist. (Mirror this in any future per-item job.)

- **Degraded states must reach every surface identically (viewer ↔ PDF ↔
  JSON export).** A `low_pose_confidence` overlay carries no drawable
  artifact, but it is still a real, exportable fact. The viewer shows it
  as a warning, so the JSON export must emit it too (with null
  `composite_url`/`overlay_svg_url` and the `pose_confidence`) rather
  than silently dropping it — surfaces must not disagree about which
  captures exist. The confidence gate is authoritative on BOTH sides: if
  the sidecar *narrows* `pose_confidence` below threshold, Rails
  re-checks `acceptable?` and persists the row as low-confidence with
  nil refs (it does not blindly trust the pre-call gate decision).

- **A live-gated sidecar stage must fail CLOSED in production, never
  OPEN.** Stages with a `*_LIVE` flag default to a hermetic placeholder
  for dev/CI. That placeholder returns a *successful, real-looking*
  response, so if production is deployed without the flag the stage
  silently emits blank artifacts that downstream trusts as real. The
  rule (extends the `CLAUDE.md` fail-fast convention to live-gated
  stages): when `SIDECAR_ENV=production`, a stage whose placeholder path
  would serve real traffic must be treated as a boot misconfiguration —
  the deploy dies at boot — AND the stage's `*_LIVE` flag must be set in
  `ops/compose.prod.yaml`. Adding a new live-gated stage means adding
  both its prod compose flag and its prod-fail-open boot guard
  (`sidecar/app/boot_checks.py`).
