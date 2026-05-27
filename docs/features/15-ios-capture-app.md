# Feature: iOS capture app (Swift, ARKit world-mesh + depth + photos + GPS/IMU)

**ID:** F-15 · **Roadmap piece:** F-15 · **Status:** Not started

## Description

A thin native iOS app per
[ADR-007](../adrs/ADR-007-mobile-capture-thin-ios-app.md): a
"smart camera" that captures the richest possible sensor bundle from
a Pro iPhone (RGB photos, per-frame depth maps via ARKit
`sceneDepth`, the ARKit world-anchored mesh
`ARMeshAnchor` accumulated over the session, GPS fixes, per-photo
IMU/orientation snapshot) and uploads it as a single multipart POST
to the backend.

UX is a **guided walk-around**: 8 prompts (4 corners + 4 facades) with
position + bearing hints; no live AR overlays; static 2D illustration
+ text + compass hint per prompt. The app does no on-device
measurement or reconstruction — all fusion math happens server-side
in F-16.

## How it fits the roadmap

Wave 2 — runs in parallel with the entire pipeline track. The
longest single-agent feature (Swift is its own ecosystem and Pro
iPhone hardware adds setup overhead). Off the critical path until
its integration partner F-16 starts; then it becomes a hard blocker
for F-16.

## Dependencies (must exist before this starts)

- **F-01 Walking skeleton** — to give the iOS app something to POST
  to.
- **F-03 Auth machinery** — `capture_token` machinery + the
  bearer-token endpoint.

## Unblocks (what waits on this)

- **F-16 iOS capture ingest + ICP fusion** — consumes the uploaded
  bundle.

## Acceptance criteria

- **Xcode project** in `ios/` directory; single Swift target; minimum
  iOS 17; depends only on Apple SDKs (ARKit, CoreLocation,
  AVFoundation, ModelIO for mesh export).
- **TestFlight build** installable on a Pro iPhone via direct
  install or TestFlight (no App Store submission).
- **Capture flow:**
  - On launch, prompts for a `capture_token` (or accepts a deep
    link `rooftrace://capture?token=...`); validates length/format.
  - Performs a one-time setup check: "verify LiDAR works by
    pointing at a wall 1 m away"; if `sceneDepth` data is absent
    or the device isn't a Pro model, surfaces a clear error
    ("This app requires an iPhone Pro or iPad Pro with LiDAR").
  - Walks through 8 prompts: front-left corner, front facade,
    front-right corner, right facade, back-right corner, back
    facade, back-left corner, left facade. Each prompt shows a
    2D illustration + text + bearing hint (compass) + "tap when
    aligned" button.
  - At each tap, captures: an RGB photo (highest resolution),
    the current frame's `sceneDepth` map, a snapshot of the
    device's `attitude` (pitch/yaw/roll), and a high-accuracy
    GPS fix.
  - Throughout the session, accumulates ARKit world-anchored mesh
    data (`ARMeshAnchor` deltas) into a session-final fused mesh.
  - On completion, exports the world mesh as a single
    USDZ/`.obj` file.
- **Upload:**
  - At session end, POSTs to `<backend>/api/v1/capture-sessions/:job_id`
    with `Authorization: Bearer <capture_token>`.
  - Multipart body contains: `session.json` (manifest with
    per-capture metadata: timestamps, GPS, IMU, depth-map file
    names), N photo files, N depth-map files (16-bit PNG or
    binary float32), one world-mesh file, an initial GPS-track
    file.
  - Shows upload progress; on success, displays "Upload complete
    — view results at [share URL]" with a tap-to-copy.
  - On failure, retries once; persistent failure shows an
    actionable error and offers a "save bundle locally" option.
- **No on-device ML or reconstruction.** This is a deliberate
  architectural constraint per ADR-007.
- **No live AR overlays** in the capture flow.
- **Pose-data accuracy:** GPS reported with horizontal accuracy
  metadata; world-mesh + per-frame depth carry session-local
  timestamps for backend ICP alignment.

## Testing requirements

- **Unit tests (Swift):** session-state machine, multipart-encoding
  correctness, token validation.
- **Manual on-device testing:** real Pro iPhone with the actual
  walk-around UX; document the manual test plan.
- **Fixture-session capture:** record one complete capture session
  bundle during development and commit it to
  `spec/fixtures/ios_sessions/<name>/` for use by F-16 and the
  stretches (F-17, F-18) when no Pro iPhone is available.
- **Upload-retry test:** simulate network failure mid-upload; verify
  retry-then-save-locally behavior.
- **Setup-check test:** simulate missing depth data; verify the
  device-requirement error UX.

## Manual setup required

- **Apple Developer account** (free or paid; free works for direct
  Xcode install to a single device, paid required for TestFlight).
- **Pro iPhone hardware** (iPhone 12 Pro or newer, any Pro model).
  If unavailable, commit to fixture-driven development and
  document this in the writeup.
- **Provisioning profile** for the test device.
- **Backend URL** configured per build (dev vs. demo deployment).

## Implementation notes (filled in by the building agent)

> The agent implementing this feature records its implementation
> decisions and rationale here as it builds — chosen libraries/patterns
> within the architecture's constraints, trade-offs made, deviations
> from assumptions and why, and anything the next agent or the
> integrator needs to know. This section starts empty and is owned by
> the builder, not the planner. Cross-cutting discoveries that affect
> other features must also be propagated to ROADMAP.md or the
> architecture doc, not just left here.
