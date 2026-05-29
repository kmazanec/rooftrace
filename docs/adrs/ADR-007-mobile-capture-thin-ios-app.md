# ADR-007: Ship a thin native iOS app that captures camera + ARKit mesh + depth + GPS + IMU and uploads to the backend

**Status:** Accepted · **Date:** 2026-05-27 · **Stretch:** no
**Supersedes:** none · **Superseded by:** none

## Context

The brief calls out "Mobile-Assisted Capture" as a core capability:

> - Guided photo capture to enhance satellite data with real-world imagery
> - Leverage on-device depth, LiDAR (where available), GPS, and motion sensors
> - Support AR-guided annotations and measurements

ADR-001 already established that satellite + public LiDAR fusion is the
headline geometry architecture. The mobile capture's job is therefore
**not** to be a standalone measurement instrument — it's to provide
*additional* on-device geometric input that the backend fuses with the
public-LiDAR / NAIP pipeline, especially in cases where public LiDAR is
absent or trees occlude the roof.

Two facts about consumer hardware shape this decision:

- **iPhone Pro models (12 Pro+) and all recent iPad Pros ship a real
  LiDAR sensor** accessible through ARKit's `sceneDepth` API and
  `ARMeshAnchor` scene-reconstruction outputs. The sensor's effective
  range is ~5 m — useless for scanning a roof from the ground, but
  excellent for scanning the *house facades* and yielding a registered
  3D mesh of the structure's walls and immediate eaves.
- **Android does not have a comparable installed base** of LiDAR
  hardware. ARCore's monocular Depth API is meaningfully worse for
  geometric reconstruction.

This skews the mobile decision toward iOS-first. CompanyCam's own stack
is "Swift native iOS **and** React Native" (COMPANY.md), so a native
Swift app is culturally aligned, not an over-investment.

The other decision under this ADR is how much *intelligence* lives on
the device. Two extremes:

- **Smart device:** the phone runs SLAM, does its own reconstruction,
  even runs vision models. Expensive to build, hard to debug, weak
  separation of concerns.
- **Smart pipe:** the device is a **smart camera** — it captures the
  richest possible sensor bundle (photos, per-frame depth, ARKit world-
  anchored mesh, GPS, IMU) and ships it to a backend that does all
  fusion math. Builds fast, debuggable, scales the backend
  independently.

## Options considered

**A. Thin native iOS app, "smart pipe" pattern — captures everything,
processes nothing, uploads to backend.** Guided walk-around UX
("stand at the front-left corner, tap shutter"). Per capture: still
photo, current frame's depth map, ARKit world-anchored mesh
delta, GPS fix, device orientation/IMU. Backend fuses with public
LiDAR (ADR-003) and NAIP imagery (ADR-002).
*Tradeoff:* ships fast (single Swift view controller + sensor bundle
+ upload), keeps complexity in the backend where the rest of the
geometry math already lives, and gives us the *strongest* possible
input from the device. Doesn't ship a polished AR experience.

**B. Web PWA + photo upload.** Mobile users go to a share link, capture
photos with WebAPIs (camera, GPS, IMU via DeviceOrientation), backend
does SfM.
*Tradeoff:* zero app-store overhead, cross-platform, but **Safari
does not expose iPhone LiDAR or ARKit's depth API.** We'd give up the
strongest input the hardware can provide, just to avoid Xcode. Wrong
tradeoff given the brief explicitly names "on-device depth, LiDAR."

**C. Expo / React Native with native module bridges to ARKit.**
Mirrors CompanyCam's RN half of the stack; cross-platform.
*Tradeoff:* native module bridges for ARKit depth/mesh are non-
trivial; community libraries (viro-react, etc.) are stale or fragile.
The 4-day window does not budget time for fighting an Expo–ARKit
bridge.

**D. Skip mobile entirely; pre-recorded demo video.** Doesn't ship the
brief's capability; cuts a graded deliverable.

**E. AR-overlay UX in-app.** ARKit world-anchored arrows guiding the
user; more striking visually.
*Tradeoff:* solid AR design is its own scope item and tends to eat
all available time. The brief asks for "AR-guided annotations and
measurements" — we satisfy "annotations" by overlaying *server-derived
measurements onto a previously-captured photo in the web viewer* (a
later ADR) rather than building live AR in the capture flow.

## Decision

**A — thin native iOS app, smart-pipe pattern.** Specifically:

- **Capture payload per session:** RGB photos (taken at user-prompted
  capture moments around the building), **per-frame depth map**
  (`AVDepthData` / ARKit `sceneDepth`), **ARKit world-anchored mesh**
  (`ARMeshAnchor` deltas as a single fused mesh at session end), GPS
  fix(es), per-photo device orientation/IMU snapshot. All wrapped in
  a single multipart upload to the backend at the end of the session.
- **UX:** **guided walk-around**, mirroring Hover's pattern. The app
  presents a sequence of position-and-orientation prompts ("Front-left
  corner, looking at the house, shutter when you're aligned") — at
  minimum the 4 corners + the 4 facades = 8 prompts. The prompt UI is
  *static*: a 2D illustration + text + bearing-compass hint; **no live
  AR arrows**.
- **No on-device measurement, no on-device ML.** The device emits the
  sensor bundle; the backend (ADR-008 forthcoming) does fusion, ICP-
  alignment to the public-LiDAR point cloud, and surface
  reconstruction.

## Rationale

This is the only path that captures the **strongest possible input the
hardware can produce** (ARKit world-anchored mesh + depth) without
spending the build budget on AR UX, native-module bridging, or
on-device ML. The geometric story upgrades from "we use public LiDAR"
to **"we use public LiDAR plus on-device LiDAR, fused via ICP" — which
addresses the brief's hardest case directly (trees overhanging the
roof: the on-device walk-around fills the gaps that aerial sources
miss).

It is also the architectural pattern a CTO will recognize immediately
as the right shape: **devices are smart cameras, servers are smart
processors.** It maps cleanly onto CompanyCam's existing mental model
— their mobile apps capture photos that the backend organizes — and
extends it with one new sensor bundle rather than introducing a new
mobile architecture.

The native-iOS-only choice rather than RN is justified by what we
need from the device: the ARKit mesh and per-frame depth APIs are
native-only in any practical sense. The CTO defense is: "iOS native
where the hardware story demands it; RN where it doesn't. We chose
the boundary at the API surface, not the org chart."

## Tradeoffs & risks

- **iOS-only (Pro models only for depth/mesh).** No Android, no
  non-Pro iPhones. Mitigation: in v1 this is acceptable — the
  *measurement* still works for these users via the satellite + public
  LiDAR path (ADR-001); the mobile enhancement is additive. Document
  the device requirement in the README.
- **We need a Pro iPhone to develop and demo.** Mitigation: if no
  device available, build against the Xcode simulator using captured
  fixture data (a recorded session bundle); demo the iOS flow with
  pre-captured data and the live web flow.
- **ARKit world-anchored mesh is large** (10–100 MB for a
  whole-house session). Mitigation: gzip + multipart upload; size
  budget documented; show user progress.
- **Sensor calibration & coordinate transforms.** ARKit returns mesh
  in a session-local coordinate frame; aligning to global / public-
  LiDAR coordinates requires GPS + IMU + ICP. Mitigation: capture
  a high-accuracy initial GPS fix at session start; backend ICP
  uses the GPS+IMU as the coarse alignment seed before fine-tuning
  against the public-LiDAR point cloud.
- **App Store review is not in budget.** Mitigation: ship as an
  **Xcode TestFlight / direct install** for the demo; App Store
  submission is post-MVP.
- **Some Pro iPhone owners' LiDAR sensors are partially obscured by
  cases.** Mitigation: a one-time setup check at app open ("verify
  LiDAR works by pointing at a wall 1 m away"); UX guidance to
  remove case if needed.

## Consequences for the build

- **`ios/` directory** in the repo: a single Xcode project, single
  Swift target, minimal dependencies (ARKit, CoreLocation, AVFoundation
  built-ins).
- **Capture session schema** (versioned): `{session_id, started_at,
  captures: [{photo_url, depth_map_url, gps, orientation,
  timestamp}], world_mesh_url, device_info}`. Uploaded as a single
  multipart POST to `/api/v1/capture-sessions`.
- **Backend endpoint** accepts the bundle and enqueues a fusion job
  (Round 4 / ADR-008): ICP-align the device mesh to the public-LiDAR
  point cloud, merge into a single unified mesh, re-run plane fitting,
  refresh the measurement with `source: lidar+device+imagery` and a
  potentially higher confidence score.
- **No AR overlay code in the iOS app v1.** The "AR-guided
  annotations" piece of the brief is satisfied later by the **web
  viewer overlaying server-derived facets onto a previously-captured
  photo** — a separate ADR in Round 5.
- **Auth between iOS app and backend** is a short-lived session
  token tied to a job_id; capture sessions are scoped to a single
  measurement job (consistent with Round 5's auth ADR).
- **Stretch path:** if time allows, add a "free-form re-capture" mode
  where the user can capture additional photos from any angle after
  the guided walk-around; v1 ships the guided flow only.

## Amendment: capture-bundle manifest freeze (manifest_version 1.0.0)

**Date:** 2026-05-28

The original "Consequences for the build" sketch above gave the capture
session schema loosely (`{session_id, started_at, captures: [...],
world_mesh_url, device_info}`). Building the ingest + ICP fusion path forced
those fields to exact types, units, enums, and serialization rules. The
manifest is now **frozen at `manifest_version` `1.0.0`** and the machine-
readable contract is `shared/ios_session_schema.json` (JSON Schema 2020-12,
`additionalProperties:false` everywhere so any field drift fails loudly). Both
sides validate against that one file: the iOS Swift `Codable` encoder produces
it, the Rails ingest validator and the Python sidecar (`json.loads` +
`jsonschema.validate`) consume it. The synthetic fixture
`spec/fixtures/ios_sessions/synthetic_house/session.json` is the conforming
reference both build against.

The decisions frozen here:

- **GPS altitude is HAE, never MSL.** `gps_origin.altitude_m` and each
  `captures[].gps.altitude_m` carry the WGS84 **ellipsoidal** height from
  `CLLocation.ellipsoidalAltitude` (iOS 15+), **never** `CLLocation.altitude`
  (orthometric / MSL). The difference is 30–50 m across CONUS; using MSL would
  silently shift the ICP coarse alignment seed by tens of meters and push the
  ARKit mesh outside the coarse capture basin. This is a one-line choice on the
  device (`ellipsoidalAltitude`) and a documented invariant here.

- **Depth maps are 16-bit grayscale PNG, uint16 millimeters.** Each capture
  carries `depth_scale` (const `1000.0`) and `depth_unit` (const
  `'mm_as_uint16'`). A pixel value `v` decodes to `v / depth_scale` meters:
  `0` mm = 0 (no depth), `1000` = 1.0 m, `65535` = 65.535 m (clamped).
  `depth_range_m` is `[min, max]` meters actually present, clamped to
  `[0.0, 65.535]`. One depth frame per prompt tap (8 total); no multi-frame
  averaging in v1.

- **Mesh is Wavefront OBJ in `arkit_session_local` coordinates.** The fused
  ARKit world mesh is exported as a single OBJ. `world_mesh.filename` is the
  const `'arkit_mesh.obj'`, `world_mesh.format` is the const `'obj'`,
  `world_mesh.coordinate_frame` is the const `'arkit_session_local'` (ARKit's
  gravity-aligned Y-up world frame, arbitrary origin, meters). The OBJ uploads
  to the Spaces key `uploads/<job_id>/arkit_mesh.obj`, which is exactly the
  `capture_mesh_ref` value the backend sends to the sidecar `fuse-capture`
  stage (`shared/pipeline_schema.json` `$defs.FuseCaptureRequest`). The earlier
  sketch's `world_mesh_url` is superseded by this storage-key convention.

- **Camera poses are serialized row-major with an explicit transpose.** Each
  capture's `camera_pose.intrinsics_row_major` is 9 numbers (row-major 3×3) and
  `camera_pose.world_to_camera_row_major` is 16 numbers (row-major 4×4
  world→camera extrinsic). ARKit's `simd_float3x3` / `simd_float4x4` are
  **column-major** in memory (`columns.0..3` are column vectors), so the
  serializer **must explicitly build rows** — row `i` of the 4×4 is
  `[columns[0][i], columns[1][i], columns[2][i], columns[3][i]]`. It must never
  flatten `Array(matrix)` (that emits column-major order and silently corrupts
  the extrinsic). These map directly onto `ProjectPhotoRequest.camera_pose`
  `intrinsics` / `extrinsics` in the pipeline schema for the AR-overlay stretch.

- **Attitude is a quaternion only.** Each capture's `attitude` carries
  `quaternion_w/x/y/z` plus a `reference_frame` string from ARKit (e.g.
  `'xArbitraryZVertical'`). No Euler angles — they are ambiguous about
  convention and lose precision near gimbal lock.

- **Multipart wire format — 18 named parts for 8 captures.** The bundle uploads
  as one multipart POST with deterministically named parts:
  `session_json` (`application/json`), `photo_00`…`photo_07` (`image/jpeg`),
  `depth_00`…`depth_07` (`image/png`), and `world_mesh` (`model/obj`). `NN` is
  the **zero-padded** `capture_index`. The backend writes each part to its
  Spaces key under `uploads/<job_id>/` (`session.json`, `photo_<NN>.jpg`,
  `depth_<NN>.png`, `arkit_mesh.obj`) before persisting any row or enqueuing the
  fusion job, so every reference is fetchable when the job runs.

The machine-readable contract for all of the above is
`shared/ios_session_schema.json`.
