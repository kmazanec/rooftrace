# Convergence report — Wave 4 (iOS capture + ICP fusion)

**Iteration slug:** `wave-4-ios-fusion` · **Build branch:** `build/wave-4-ios-fusion`
**Barrier commit:** `38c669a` · **Convergence HEAD:** `b7ee449`
**Built:** 2026-05-28 · **Status:** ready for human landing as one MR

This is a handoff artifact (intentionally left untracked — not part of the MR).
It records what the autonomous build produced, what was verified here, and the
exact steps for a human to land it.

---

## What landed

Both approved Wave 4 features, stacked on a single frozen-contract barrier
commit, then assembled onto `build/wave-4-ios-fusion`.

### Contract barrier (`38c669a`, B-1..B-8)
- `shared/ios_session_schema.json` — JSON Schema 2020-12 for the `session.json`
  capture manifest (`manifest_version` 1.0.0). Both Swift (F-15) and Python
  (F-16) build to it; validated in CI.
- ADR-007 amendment documenting the frozen capture-bundle contract (HAE GPS,
  16-bit uint16 mm depth, Wavefront OBJ mesh, row-major camera-pose transpose,
  quaternion attitude, multipart part naming).
- Synthetic fixture bundle `spec/fixtures/ios_sessions/synthetic_house/`
  (session.json + 8 JPEGs + 8 16-bit depth PNGs + `arkit_mesh.obj` offset
  +0.5m N/+0.3m E from the LiDAR cloud as ICP ground truth) +
  `synthetic_house_lidar.npy` + deterministic `generate_fixture.py` + README.
  GPS origin from the Lincoln NE validation address (EPSG:32614).
- `spec/fixtures/pipeline/fuse_capture_response.valid.json` +
  `…no_measurement.valid.json`; fixed the existing request fixture's
  `capture_mesh_ref` from `arkit_mesh.bin` → `arkit_mesh.obj` (contract).
- `SidecarClient#fuse_capture` (instance + class) + `FUSE_CAPTURE_TIMEOUT_SECONDS`,
  with `spec/services/sidecar_client_fuse_spec.rb` green.
- `shared/PIPELINE_SCHEMA_CHANGELOG.md` updated (FuseCapture implemented at
  0.3.0, manifest frozen at 1.0.0 — no schema version bump).
- The two per-spec build-plan headings flipped from `approved-pending` →
  `approved` (manifest sign-off is authoritative).

### F-15 — iOS Capture App (`build/wave-4-ios-fusion-f15-ios-capture`)
- SwiftUI/ARKit app under `ios/`: token entry + deep link, LiDAR setup check,
  8-prompt guided walk-around, depth/photo/mesh capture, multipart streaming
  upload with one retry, save-locally recovery.
- Codable `CaptureSessionManifest` mirroring the frozen schema; **explicit
  ARKit column-major → row-major transpose** in `MatrixSerializer`.
- 16-bit PNG `DepthMapEncoder` (float32 m → uint16 mm, clamp 65535).
- Swift unit tests for every Phase-2/7 item (token, matrix, manifest, state,
  depth, multipart, retry, fixture-parse).
- Rails touch point: `before_action :reject_oversized_request!` returning 413,
  plus extended `spec/requests/capture_sessions_spec.rb`.
- `.github/workflows/ios.yml` (additive macOS-14 runner: xcodebuild build+test +
  the Python jsonschema step). `ios/MANUAL_TEST_PLAN.md` for device QA.
- **Review:** 6-lens adversarial panel, 3 rounds, 0 unresolved findings.

### F-16 — iOS Ingest + ICP Fusion (`build/wave-4-ios-fusion-f16-icp-fusion`)
- `CaptureSession` + `Capture` models/migrations (UUID PKs, unique
  `session_id` index for idempotency), `Job has_many :capture_sessions`.
- `CaptureSessionsController#create` real ingest: validate manifest, upload
  `session.json`/`arkit_mesh.obj`/photos/depths to `uploads/<job_id>/…` BEFORE
  persisting rows, transactional `CaptureSession`+`Capture` create, duplicate
  POST → 200 without re-enqueue, then `FusionJob.perform_later`.
- `FusionJob` + `FusionOrchestrator`: **additive** new Measurement row (count
  1→2, newest `generated_at` wins via `latest_measurement`); **never** calls
  `advance_to!`/`fail_with!`; ICP failure / sidecar 5xx appends an idempotent
  warning to the existing measurement and leaves `job.status == 'ready'`.
  Confidence = `prior + 0.05 + clamp((0.5 - icp_rmse_m)*0.1, 0, 0.15)` clamped
  to `[prior, 1.0]`; fused DB `source = 'lidar+device+imagery'`.
- Turbo `[job, :fusion_status]` stream + `app/views/jobs/_fusion_status.html.erb`;
  `jobs/show.html.erb` wired with `turbo_stream_from` + idle div. Broadcast
  outside the transaction.
- Sidecar `POST /pipeline/fuse-capture` (`sidecar/app/fuse_capture/`): OBJ
  parser (line-by-line, no eval, 5M vertex cap), Open3D point-to-plane two-pass
  ICP with GPS→UTM seed, size guards, `np.load(allow_pickle=False)`,
  `MeasurementGeometry → Measurement` adaptation, `GeometrySource.FUSION`.
  `FUSE_CAPTURE_LIVE=1` boot check (open3d importable) + compose/env wiring.
- **Review:** 6-lens adversarial panel, 2 rounds, 0 unresolved findings.

---

## Merge outcome

F-16 was committed directly on the build branch at barrier+1 (`33ee4dd`).
F-15 was merged in `--no-ff` (convergence HEAD `b7ee449`). Two conflicts on the
shared ingest endpoint, both reconciled:

1. **`app/controllers/api/v1/capture_sessions_controller.rb`** (textual) — F-16's
   full real-ingest body already had a 413 guard; F-15 added a separate
   `before_action` size check. **Resolved:** kept F-16's ingest, folded F-15's
   early-rejection intent into a single `before_action :reject_oversized_request!`
   on one `MAX_BUNDLE_BYTES = 500.megabytes` cap (rejects before parsing/upload),
   dropped the duplicate 200MB constant + redundant in-action check. `ruby -c` clean.
2. **`spec/requests/capture_sessions_spec.rb`** (semantic mis-auto-merge — git
   concatenated both with no marker) — F-15's stub-era block asserted the OLD
   `head :ok` behavior (now real ingest → 400 for a bare session_json part) and
   referenced the removed constant. **Resolved:** removed the superseded stub
   block (F-16's real-ingest examples cover it) and replaced its size example
   with one asserting the `before_action` 413 on oversized `CONTENT_LENGTH`.
   Shared auth/job-credential examples untouched.

> ⚠️ **Manual-review hotspot:** confirm `MAX_BUNDLE_BYTES = 500MB` is the intended
> single size cap — F-15's spec proposed a 200MB cap, which was dropped in favor
> of F-16's 500MB. If 200MB is desired, change the one constant.

---

## Integrated test results (verified here)

- **Rails `bundle exec rspec`** (bare, PostGIS @ localhost:5433):
  **`528 examples, 3 failures`** — all 3 failures are **pre-existing, unrelated**
  browser system specs (`pdf_report_spec.rb:58`, `:85` → Grover/Puppeteer not
  installed; `report_viewer_spec.rb:31` → no built JS island). Last modified
  before the barrier; they need a CI runner with the JS/Chromium toolchain.
- **End-to-end smoke** (`fusion_integration_spec.rb` + `capture_sessions_spec.rb`):
  **`22 examples, 0 failures`** — the full round-trip: multipart ingest →
  `CaptureSession`+`Capture` rows → `FusionJob` → additive Measurement
  (count 1→2, `source == 'lidar+device+imagery'`, confidence ≥ prior, original
  intact); failure path leaves count at 1 with an `icp_alignment_failed` warning.
- **Sidecar `uv run pytest -v`**: **`318 passed, 11 warnings`** — open3d 0.19.0
  installed, so **ICP tests ran for real, not skipped** (`test_fuse_capture_icp.py`
  + `test_fuse_capture_endpoint.py`: `12 passed`). Convergence on the synthetic
  fixture met the acceptance gate (RMSE < 0.15m, ≥ 80% within 0.1m).
- **Schema validation**: `SCHEMA VALIDATION OK`
  (`synthetic_house/session.json` vs `shared/ios_session_schema.json`).

---

## Untestable in this environment (covered elsewhere)

- **iOS xcodebuild / ARKit hardware** — Swift unit tests are written and the
  `.github/workflows/ios.yml` macOS-14 runner job covers build+test. ARKit
  sensor services (live `sceneDepth`, `MeshExporter` MDL export, CoreLocation)
  and `ios/MANUAL_TEST_PLAN.md` execution + the `real_capture/` fixture +
  TestFlight distribution need the physical iPhone 15 Pro.
- **Production ICP path** against a live DO Spaces bucket with a real device
  capture (`FUSE_CAPTURE_LIVE=1`) — covered here only by fixtures + local-root
  storage.

---

## Manual-review hotspots for the MR

1. ARKit column-major → row-major transpose in `MatrixSerializer.swift`.
2. ICP convergence + the `< 0.15m` / `≥ 80%-within-0.1m` acceptance gate in
   `sidecar/app/fuse_capture/icp.py`.
3. The **never-call-`advance_to!`** invariant — fusion adds a Measurement, never
   mutates job state (`fusion_integration_spec` asserts original intact + 1→2).
4. The reconciled `MAX_BUNDLE_BYTES = 500MB` single size cap (see warning above).

---

## How to land it (one linear MR)

`main` advanced by one commit since wave-4 branched (`368c3b1 fix(deploy)` —
touches only `infra/deploy.sh`, which wave-4 does not touch), so a plain
fast-forward is **not** possible. Rebase first (conflict-free), then ff-only:

```bash
# from the primary checkout on main
cd /Users/keith/dev/gauntlet/companycam/rooftrace

# rebase the build branch onto current main (no conflicts expected —
# disjoint files; the one main commit is deploy.sh only)
git rebase main build/wave-4-ios-fusion

# fast-forward main to the rebased branch (linear history)
git checkout main
git merge --ff-only build/wave-4-ios-fusion

# CI runs the iOS xcodebuild job + the JS-dependent system specs that can't
# run in the sandbox; confirm green there before/with the push.
```

Then tear down the wave-4 build worktrees + branches once collected:

```bash
git worktree remove .claude/worktrees/wave-4-ios-fusion/_build
git worktree remove .claude/worktrees/wave-4-ios-fusion/f15-ios-capture
git worktree remove .claude/worktrees/wave-4-ios-fusion/f16-icp-fusion
git branch -D build/wave-4-ios-fusion \
  build/wave-4-ios-fusion-f15-ios-capture \
  build/wave-4-ios-fusion-f16-icp-fusion
```

> The two locked `wf_f3372020-*` worktrees in `git worktree list` are unrelated
> to wave-4 — leave them.
