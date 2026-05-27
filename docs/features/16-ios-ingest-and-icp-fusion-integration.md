# Feature: INTEGRATION — iOS capture ingest + ICP fusion

**ID:** F-16 · **Roadmap piece:** F-16 · **Status:** Not started · **Type:** Integration

## Description

This is the second **integration feature**: it wires the iOS app's
capture upload (F-15) into the backend pipeline (F-10) and produces a
fused measurement using ICP (Iterative Closest Point) alignment of
the ARKit world-mesh to the public-LiDAR point cloud. Per
[ADR-007](../adrs/ADR-007-mobile-capture-thin-ios-app.md), all the
fusion math happens server-side.

The backend half has two responsibilities:

1. **Ingest the multipart bundle** in Rails: ActiveStorage uploads,
   parse the session manifest, persist `CaptureSession` and `Capture`
   rows linked to the job.
2. **Run FusionJob** (Solid Queue): the sidecar ICP-aligns the
   ARKit mesh to the public-LiDAR points using GPS+IMU as the
   coarse seed, merges the two clouds into a unified mesh, re-runs
   the plane-fit pipeline (F-08), and updates the `Measurement`
   with `source: "lidar+device+imagery"` and a raised confidence
   score.

Why it's an integration feature: it joins two parallel tracks (iOS +
geometry pipeline) and has acceptance criteria written against the
combined behavior. ICP alignment is the load-bearing risk — the
acceptance demands a numerical alignment-error metric below
threshold on a fixture session.

## How it fits the roadmap

**Wave 4 — second integration node.** On the critical path. Depends
on both the iOS app (F-15) and the orchestrator (F-10) being ready.
Unblocks both stretches (F-17, F-18).

## Dependencies (must exist before this starts)

- **F-10 Measurement orchestrator** — the base pipeline must produce
  a measurement with a LiDAR point cloud to align against.
- **F-15 iOS capture app** — sends the multipart bundle this
  feature ingests.

## Unblocks (what waits on this)

- **F-17 Claim-defensibility PDF** — uses iOS visit timestamps + evidence
  photos.
- **F-18 Server-side AR overlay** — uses fused mesh + per-photo poses
  to project facets.

## Acceptance criteria

The acceptance is **combined end-to-end behavior**:

- **Ingest endpoint:** `POST /api/v1/capture-sessions/:job_id`
  (bearer-token auth from F-03) accepts the iOS multipart bundle:
  - Parses `session.json`; persists a `CaptureSession` row linked
    to the `Job`; persists one `Capture` per photo with its
    metadata (GPS, IMU, depth-map ref, photo ref).
  - Uploads photos, depth maps, and world-mesh to
    `s3://rooftrace-uploads/<job_id>/`.
  - Returns 200 with the persisted `CaptureSession` id.
  - Rejects (400) malformed bundles with a clear error.
  - Rejects (401) expired/wrong tokens.
- **FusionJob (Solid Queue):**
  - Enqueued automatically when ingest completes.
  - Calls the sidecar `POST /pipeline/fuse-capture` with the
    job_id and session_id.
  - The sidecar:
    1. Loads the public-LiDAR point cloud (cached from F-06) and
       the ARKit world mesh.
    2. Uses GPS + IMU from the session manifest as the coarse
       seed for ICP.
    3. Runs ICP alignment (point-to-plane variant, RANSAC-robust)
       to fine-align the ARKit mesh into the public-LiDAR
       coordinate frame.
    4. Reports alignment metrics: RMSE in meters, percent of
       ARKit-mesh vertices within 0.1 m of the LiDAR surface
       (success threshold ≥ 80%).
    5. Merges the two point clouds; re-runs F-08's plane-fit
       endpoint on the merged cloud.
  - Returns the updated measurement; Rails updates the
    `Measurement` row's `source` to `"lidar+device+imagery"` and
    confidence to a value ≥ the previous confidence.
- **Acceptance test on a fixture iOS session:**
  - Ingest succeeds; the `CaptureSession` row exists with the
    correct counts.
  - FusionJob completes within 60 seconds.
  - ICP alignment RMSE < 0.15 m on the fixture.
  - The post-fusion `Measurement.source == "lidar+device+imagery"`.
  - The post-fusion `Measurement.confidence` ≥ the pre-fusion
    confidence.
- **Failure modes:**
  - ICP fails to converge (RMSE > 0.5 m): the measurement is
    *not* updated; a warning is added to the measurement
    `("icp_alignment_failed: rmse=<value>")`; the original
    LiDAR-only measurement remains the canonical answer.
  - Sidecar fusion error: 5xx with logged error; the original
    measurement stands; UI shows "fusion failed, see original
    measurement" message.
- **Status broadcasting:** the ActionCable channel (F-11) gets
  additional events: `fusion_started`, `fusion_complete` (or
  `fusion_failed`), so the UI surfaces the additive step.

## Testing requirements

- **End-to-end integration test in CI:** uses the fixture session
  bundle committed by F-15; runs ingest → FusionJob; asserts the
  measurement updates as expected.
- **Contract test:** ingest endpoint rejects malformed bundles
  with clear errors (missing fields, malformed manifest, wrong
  token).
- **ICP-convergence test:** the fixture session reliably converges
  to RMSE < 0.15 m (catches algorithm regressions).
- **Failure-isolation test:** an intentionally-perturbed fixture
  session that should not align triggers the "icp_alignment_failed"
  path without breaking the original measurement.
- **Performance test:** ingest + fusion completes in <90 seconds on
  the fixture.

## Manual setup required

- **A committed fixture iOS session bundle** in
  `spec/fixtures/ios_sessions/` (delivered as part of F-15).
- **Sidecar dependencies for ICP:** Open3D's
  `pipelines.registration.registration_icp` works out of the box;
  PDAL also has `filters.icp`. Pick one and document in the
  builder's implementation notes.

## Implementation notes (filled in by the building agent)

> The agent implementing this feature records its implementation
> decisions and rationale here as it builds — chosen libraries/patterns
> within the architecture's constraints, trade-offs made, deviations
> from assumptions and why, and anything the next agent or the
> integrator needs to know. This section starts empty and is owned by
> the builder, not the planner. Cross-cutting discoveries that affect
> other features must also be propagated to ROADMAP.md or the
> architecture doc, not just left here.
