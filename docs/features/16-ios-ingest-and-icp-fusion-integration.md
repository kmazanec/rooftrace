# Feature: INTEGRATION — iOS capture ingest + ICP fusion

**ID:** F-16 · **Roadmap piece:** F-16 · **Status:** Done (merged to main) · **Type:** Integration

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


## Build plan (approved)

> Generated by the plan-iteration pass (2026-05-28) for iteration
> `wave-4-ios-fusion`. Reconciled from an architect / researcher / contrarian
> draft, then judged into this plan. **Status: APPROVED (Keith, 2026-05-28)** —
> the build-iteration pass consumes these checkboxes plus the frozen contracts,
> shared barrier, and DAG in [`../BUILD-PLAN.md`](../BUILD-PLAN.md). Model tier: `opus`.

Builds against the barrier artifacts from `../BUILD-PLAN.md` (frozen
`session.json` manifest + synthetic fixture + `SidecarClient#fuse_capture`
stub), so it runs FULLY PARALLEL with F-15 — its CI acceptance tests use the
synthetic fixture, never a real device capture. The load-bearing invariants:
fusion is **additive** (a new `Measurement` row, newest `generated_at` wins via
`Job#latest_measurement`); the `:ready` job status is **never** touched
(`advance_to!`/`fail_with!` are never called); and an ICP failure or sidecar
error leaves the original measurement canonical.

### Ordered build steps (test-first)


**PHASE 1 — RAILS MODELS + MIGRATIONS (run from repo root)**

- [ ] 1.1 bin/rails generate migration CreateCaptureSessions — edit generated file: uuid PK (enable: :uuid default gen_random_uuid()), job_id uuid NOT NULL with index, session_id string NOT NULL with unique index, manifest_version string NOT NULL, started_at datetime, ended_at datetime, gps_seed jsonb, device_info jsonb, world_mesh_ref string, world_mesh_vertex_count integer, raw_manifest jsonb, timestamps.
- [ ] 1.2 bin/rails generate migration CreateCaptures — edit generated file: uuid PK, capture_session_id uuid NOT NULL with index, sequence_index integer NOT NULL, prompt_label string, captured_at datetime, photo_ref string, depth_ref string, gps jsonb, attitude jsonb, camera_intrinsics jsonb, camera_extrinsics jsonb, timestamps.
- [ ] 1.3 Create app/models/capture_session.rb: belongs_to :job, has_many :captures dependent: :destroy, validates :session_id presence + uniqueness, validates :job_id presence, validates :manifest_version presence.
- [ ] 1.4 Create app/models/capture.rb: belongs_to :capture_session, validates :sequence_index presence.
- [ ] 1.5 Add has_many :capture_sessions, dependent: :destroy to app/models/job.rb.
- [ ] 1.6 bin/rails db:test:prepare — verify structure.sql loads clean. Write spec/models/capture_session_spec.rb and spec/models/capture_spec.rb; run bundle exec rspec spec/models/ green.

**PHASE 2 — RAILS INGEST SERVICES**

- [ ] 2.1 Create app/services/session_manifest_validator.rb — plain Ruby value object: validates required fields (session_id present, manifest_version major == '1', gps_seed present with latitude/longitude/altitude_m/horizontal_accuracy_m/vertical_accuracy_m, captures array non-empty, world_mesh.filename == 'arkit_mesh.obj', world_mesh.format == 'obj'). Returns {valid: bool, errors: [string]}. No external gems.
- [ ] 2.2 Create app/services/spaces_uploader.rb — prefix-locked to uploads/, wraps Aws::S3::Client#put_object with key:, body: (IO), content_type: kwargs. In test/dev with STORAGE_LOCAL_ROOT set, writes to local directory (mirrors sidecar storage.py local-root pattern). Streams IO without reading into memory.

**PHASE 3 — CAPTURE SESSIONS CONTROLLER (replaces stub)**

- [ ] 3.1 Replace CaptureSessionsController#create stub body with real ingest. Refactor authenticate_capture_token! to assign @job ivar. Steps: (a) parse params[:session] as JSON via SessionManifestValidator; return 400 on validation failure with errors array. (b) Validate manifest job_id matches params[:job_id]; return 400 on mismatch. (c) Check request.content_length <= 500.megabytes; return 413 if exceeded. (d) Upload world_mesh, each photo (params[:photo_NN]), each depth map (params[:depth_NN]) to Spaces via SpacesUploader (key: uploads/<job.id>/arkit_mesh.obj, uploads/<job.id>/photo_NN.jpg, uploads/<job.id>/depth_NN.png). Also upload session.json to uploads/<job.id>/session.json BEFORE creating DB rows. (e) Wrap CaptureSession.create! + Capture.create! in a transaction; rescue ActiveRecord::RecordNotUnique — find existing session by session_id and return 200 with its id WITHOUT re-enqueueing FusionJob (idempotency). (f) FusionJob.perform_later(job.id, capture_session.id) only on new session. (g) render json: { capture_session_id: capture_session.id }, status: :ok.
- [ ] 3.2 Extend spec/requests/capture_sessions_spec.rb: valid multipart returns 200 with capture_session_id; creates CaptureSession+Capture rows; enqueues FusionJob; duplicate session_id returns 200 without re-enqueue; missing session part returns 400; manifest missing gps_seed returns 400; manifest_version '2.0' returns 400; job_id mismatch returns 400; oversized returns 413. Run bundle exec rspec spec/requests/ green.

**PHASE 4 — FUSION JOB + ORCHESTRATOR**

- [ ] 4.1 Create app/jobs/fusion_job.rb mirroring GeometryJob exactly: MAX_ATTEMPTS=3, queue_as :default, retry_on StandardError attempts: MAX_ATTEMPTS wait: :polynomially_longer. perform(job_id, capture_session_id): load Job and CaptureSession; guard return if job.latest_measurement&.source == 'lidar+device+imagery' (idempotency — already fused); call FusionOrchestrator.call(job, capture_session). In rescue StandardError: intermediate attempts (executions < MAX_ATTEMPTS) call job.update!(last_error: ...) WITHOUT calling advance_to! or fail_with!; final attempt (executions >= MAX_ATTEMPTS) calls FusionOrchestrator.append_failure_warning(job, 'fusion_job_exhausted') and raises. NEVER calls advance_to! or fail_with! under any circumstance.
- [ ] 4.2 Create app/services/fusion_orchestrator.rb: class method call(job, capture_session). Steps: (1) guard: if job.latest_measurement.nil? or job.latest_measurement.dig('lidar', 'status') != 'LIDAR_AVAILABLE' — append 'icp_skipped: lidar_unavailable' warning to existing measurement, broadcast fusion_failed with reason :lidar_unavailable, return nil; (2) broadcast fusion_started to [job, :fusion_status]; (3) prior = job.latest_measurement; (4) call SidecarClient.fuse_capture(job_id: job.id, capture_mesh_ref: capture_session.world_mesh_ref, lidar: prior.lidar, timeout: SidecarClient::FUSE_CAPTURE_TIMEOUT_SECONDS); (5) if response['measurement'].nil? or response['icp_rmse_m'].to_f >= 0.5 — append_failure_warning(job, "icp_alignment_failed: rmse=#{response['icp_rmse_m']}m"), broadcast fusion_failed with state: :failed icp_rmse_m: response['icp_rmse_m'], return nil; (6) on convergence: create new Measurement row inside Job.transaction (NOT inside job.transaction — fusion is additive, not a re-run of the pipeline transaction); broadcast fusion_complete. Defines self.append_failure_warning(job, message) — idempotent check (skip if message already in warnings) then measurement.update!(warnings: measurement.warnings + [message]).
- [ ] 4.3 Create app/views/jobs/_fusion_status.html.erb: renders appropriate text/icon based on state local (:idle, :started, :complete, :failed). Ensure jobs/show.html.erb includes turbo_stream_from([job, :fusion_status]) and a div with id=dom_id(job, :fusion_status) rendered with state: :idle.
- [ ] 4.4 Write spec/services/fusion_orchestrator_spec.rb (4 scenarios with stubbed SidecarClient): happy path creates new Measurement + broadcasts fusion_complete; ICP failure (rmse >= 0.5) appends warning + broadcasts fusion_failed; sidecar 5xx appends warning + broadcasts fusion_failed; LIDAR_MISSING job broadcasts fusion_failed reason :lidar_unavailable and makes no SidecarClient call. Assert advance_to! and fail_with! are NEVER called (verify job.reload.status == 'ready' throughout).
- [ ] 4.5 Write spec/jobs/fusion_job_spec.rb: happy path delegates to FusionOrchestrator; intermediate failure records last_error without terminal status (job.status remains ready); final attempt appends fusion_job_exhausted warning; idempotency guard (already-fused measurement skips re-run). Run green.

**PHASE 5 — SIDECAR FUSE-CAPTURE ENDPOINT**

- [ ] 5.1 Add open3d>=0.18.0 to sidecar/pyproject.toml dependencies. Run cd sidecar && uv sync. Verify python -c 'import open3d; print(open3d.__version__)' succeeds.
- [ ] 5.2 Create sidecar/app/fuse_capture/__init__.py (empty).
- [ ] 5.3 Create sidecar/app/fuse_capture/mesh_io.py: parse_obj(data: bytes) -> np.ndarray reads Wavefront OBJ format, extracts 'v x y z' vertex lines, returns (N,3) float64. Vertex limit 5M. Returns empty array on no-vertex input. Security: no eval, purely line-by-line string parsing.
- [ ] 5.4 Create sidecar/app/fuse_capture/icp.py: AlignResult dataclass {transformation: np.ndarray (4x4), rmse_m: float, pct_within_0_1m: float, converged: bool, fitness: float}. align_mesh_to_lidar(mesh_pts, lidar_pts, gps_seed, utm_epsg) -> AlignResult. GPS->UTM via pyproj Transformer.from_crs('EPSG:4326', f'EPSG:{utm_epsg}').transform(lat, lon). Build 4x4 init_transform from UTM translation (arkit_centroid to lidar_centroid + GPS anchor correction). estimate_normals on both clouds (KDTreeSearchParamHybrid radius=0.5 max_nn=30). Pass 1 coarse (max_correspondence_distance=0.5, max_iteration=50, TransformationEstimationPointToPlane). Pass 2 refine (max_correspondence_distance=0.15, max_iteration=30). Compute pct_within_0_1m via compute_point_cloud_distance. converged = (rmse_m < 0.5) AND (fitness > 0.2).
- [ ] 5.5 Create sidecar/app/fuse_capture/router.py: APIRouter prefix=/pipeline tags=[fuse_capture]. POST /pipeline/fuse-capture route. Steps: _check_version; load session manifest from uploads/<req.job_id>/session.json via get_bytes to extract gps_seed and utm_epsg (from req.lidar.work_unit.epsg if present, else derive from gps_origin lon via zone formula); load ARKit OBJ from req.capture_mesh_ref via get_bytes + mesh_io.parse_obj; load LiDAR .npy from req.lidar.point_array_ref via get_bytes + np.load(allow_pickle=False) + [:, :3]; size guards (256 MiB each); call align_mesh_to_lidar; if not converged return FuseCaptureResponse(measurement=None, icp_rmse_m=result.rmse_m); if converged: np.vstack merged cloud, call fit_planes + build_facets_from_planes + assemble_measurement from sidecar.app.planefit (same functions used by /fit-planes endpoint), set source=GeometrySource.FUSION, return FuseCaptureResponse with full Measurement and icp_rmse_m.
- [ ] 5.6 Mount fuse_capture router in sidecar/app/main.py: add 'from .fuse_capture.router import router as fuse_capture_router' and 'app.include_router(fuse_capture_router, dependencies=_PIPELINE_DEPS)'.
- [ ] 5.7 Add FUSE_CAPTURE_LIVE boot check to sidecar/app/boot_checks.py: _fuse_capture_enabled checks env.get('FUSE_CAPTURE_LIVE','') == '1'; _fuse_capture_missing verifies open3d is importable (same pattern as _imagery_missing for rasterio). Add _StageCheck(stage='fuse_capture', is_enabled=_fuse_capture_enabled, required_vars=_fuse_capture_missing) to _CHECKS list.
- [ ] 5.8 Add FUSE_CAPTURE_LIVE=1 to ops/compose.prod.yaml sidecar env block and to ops/.env.example with comment explaining it enables the real ICP path.

**PHASE 6 — SIDECAR TESTS**

- [ ] 6.1 Create sidecar/tests/fixtures/f16/generate_fixtures.py: generates lidar_cloud.npy (synthetic gable roof 500 points (500,4) float64 local-UTM-like coords), arkit_mesh.obj (same vertices + 0.3m north translation in OBJ format), arkit_mesh_bad.obj (20m translation for guaranteed non-convergence). Run and commit all three fixture files.
- [ ] 6.2 Write sidecar/tests/test_fuse_capture_icp.py: (a) convergence test using f16 fixtures — rmse_m < 0.15, pct_within_0_1m >= 0.8; (b) non-convergence test using arkit_mesh_bad.obj — converged=False, rmse_m > 0.5; (c) GPS->UTM seed for known coord; (d) parse_obj round-trip from minimal OBJ bytes; (e) parse_obj rejects > 5M vertex input.
- [ ] 6.3 Write sidecar/tests/test_fuse_capture_endpoint.py: (a) happy path POST with f16 fixtures returns 200, measurement populated, icp_rmse_m < 0.15; (b) bad alignment returns 200 with measurement=null, icp_rmse_m > 0.5; (c) missing capture_mesh_ref returns 422; (d) schema version mismatch returns 409; (e) no bearer returns 401; (f) pickle-bearing npy returns 422. Uses local-root storage (STORAGE_LOCAL_ROOT) with f16 fixtures at appropriate paths.
- [ ] 6.4 Extend sidecar/tests/test_boot_checks.py: FUSE_CAPTURE_LIVE=1 with open3d importable -> no problems; FUSE_CAPTURE_LIVE=1 with open3d missing -> problem reported; FUSE_CAPTURE_LIVE unset -> no check. Run cd sidecar && uv run pytest -v green.

**PHASE 7 — INTEGRATION TEST**

- [ ] 7.1 Write spec/requests/fusion_integration_spec.rb: POST spec/fixtures/ios_sessions/synthetic_house/ multipart (using fixture files as IO objects) to the ingest endpoint; assert CaptureSession+Capture rows created; run FusionJob.perform_now with SidecarClient stubbed to return fuse_capture_response.valid.json fixture; assert job.measurements.count == 2; assert job.latest_measurement.source == 'lidar+device+imagery'; assert job.latest_measurement.confidence >= prior_confidence; assert original Measurement still exists with source unchanged. Failure path: stub returns fuse_capture_response.no_measurement.valid.json; assert measurements.count == 1; assert job.latest_measurement.warnings.any? { |w| w.include?('icp_alignment_failed') }. Performance tag: completes in < 90s.

**PHASE 8 — DOCUMENTATION**

- [ ] 8.1 Fill docs/features/16-ios-ingest-and-icp-fusion-integration.md Implementation Notes: Open3D choice justification (pip-installable vs PDAL conda-only), additive Measurement model decision, confidence formula, FusionJob/advance_to! non-call rationale, GPS seed extraction from uploaded session.json, known limitations.

### CI-gating tests

- [ ] spec/models/capture_session_spec.rb — associations, presence validations, session_id uniqueness
- [ ] spec/models/capture_spec.rb — belongs_to :capture_session, sequence_index presence
- [ ] spec/requests/capture_sessions_spec.rb (extended) — valid multipart returns 200+capture_session_id; creates DB rows; enqueues FusionJob; duplicate returns 200 without re-enqueue; missing session returns 400; malformed manifest returns 400; manifest_version 2.0 returns 400; job_id mismatch returns 400; oversized returns 413
- [ ] spec/services/sidecar_client_fuse_spec.rb — FuseCaptureRequest validates against schema; response parse from both valid and no_measurement fixtures
- [ ] spec/services/fusion_orchestrator_spec.rb — happy path creates Measurement + broadcasts; ICP failure appends warning + broadcasts; sidecar 5xx appends warning; LIDAR_MISSING broadcasts without sidecar call; job.status never changes from ready
- [ ] spec/jobs/fusion_job_spec.rb — delegates to orchestrator; intermediate failure records last_error without terminal status; final attempt appends warning; idempotency guard
- [ ] spec/requests/fusion_integration_spec.rb — full round-trip with mocked sidecar: measurements.count==2, source==lidar+device+imagery, confidence>=prior, original intact; failure path leaves count==1 with warning
- [ ] sidecar/tests/test_fuse_capture_icp.py — ICP convergence (rmse<0.15m, pct>=0.8); non-convergence (rmse>0.5m); GPS->UTM seed; parse_obj round-trip; vertex limit
- [ ] sidecar/tests/test_fuse_capture_endpoint.py — happy 200+measurement+rmse<0.15; bad alignment 200+null+rmse>0.5; missing ref 422; version mismatch 409; no bearer 401; pickle npy 422
- [ ] sidecar/tests/test_boot_checks.py (extended) — FUSE_CAPTURE_LIVE=1 check passes with open3d; fails in prod mode without open3d

### Top risks the build must bake in

- **ICP non-convergence on the synthetic fixture in CI: GPS seed does not place ARKit mesh within 0.5m capture basin** — generate_fixtures.py creates arkit_mesh.obj by applying exactly 0.3m north translation to lidar_cloud.npy vertices — well within the 0.5m coarse capture basin. GPS seed in session.json is derived by inverse-projecting lidar_cloud.npy UTM centroid to WGS84, guaranteeing init_transform places ARKit origin within < 0.1m of LiDAR centroid. 0.3m perturbation is a controlled refinement problem Open3D point-to-plane ICP solves in < 20 iterations. Pin open3d>=0.18.0 (not exact pin) to allow patch updates while keeping the API stable.
- **FusionJob accidentally calls advance_to! or fail_with! on an already-:ready job, raising ArgumentError or corrupting job status** — FusionJob and FusionOrchestrator contain zero calls to advance_to! or fail_with!. All status feedback goes to the separate [job, :fusion_status] Turbo stream. fusion_orchestrator_spec explicitly asserts job.reload.status == 'ready' throughout all code paths including error paths. advance_to!'s terminal guard (already in job.rb) would raise ArgumentError as a loud test failure if someone accidentally adds such a call.
- **Open3D pip wheel conflicts with conda-forge GDAL/rasterio stack in sidecar image (numpy C ABI mismatch or bundled pybind11 collision)** — Open3D >= 0.18 requires numpy >= 1.23; sidecar already pins numpy >= 2.4.6. Open3D ships compiled extensions against numpy stable C ABI. FUSE_CAPTURE_LIVE boot check verifies open3d importable at sidecar startup — a failed import fails the boot in production with a clear message. Add python -c 'import open3d' verification step during Docker image build (non-fatal in dev, informational).
- **Double-enqueue from iOS retry creates duplicate fused Measurement rows** — Unique index on capture_sessions.session_id is the primary guard. Second POST rescues ActiveRecord::RecordNotUnique and returns 200 with the existing session id WITHOUT enqueuing FusionJob. session_id is generated once in iOS at session start and is stable across all retry attempts (UploadRetryTests verifies this on the Swift side).
- **Sidecar reads uploads/<job_id>/session.json but file may not be uploaded yet (race with FusionJob enqueueing before file upload completes)** — CaptureSessionsController uploads session.json to Spaces BEFORE persisting the CaptureSession row and BEFORE enqueuing FusionJob (strictly ordered). Solid Queue job is enqueued only after the controller transaction commits. Sidecar returns 422 if get_bytes fails for session.json, which FusionJob treats as a retryable StandardError (polynomially_longer retry up to MAX_ATTEMPTS).
- **source: 'lidar+device+imagery' fails schema validation in FuseCaptureResponse.measurement (GeometrySource enum is lidar/imagery/fusion/capture/manual)** — Sidecar returns source=GeometrySource.FUSION ('fusion') in the Measurement embedded in FuseCaptureResponse — a valid enum value. FusionOrchestrator maps this to the Rails display string 'lidar+device+imagery' when creating the Measurement DB row. measurements.source is a varchar column with no DB-level enum constraint. No schema version bump needed.

## Implementation notes (filled in by the building agent)

**ICP library — Open3D, not PDAL.** The fusion stage uses Open3D's
`pipelines.registration.registration_icp` (point-to-plane, two-pass). Open3D
ships a compiled pip wheel that installs into the uv-managed virtualenv with no
conda; PDAL's `filters.icp` requires the conda-only PDAL package, which the
sidecar's uv toolchain can't pull. Open3D 0.19 imports cleanly against the
sidecar's pinned `numpy>=2.4.6`. A boot check (`FUSE_CAPTURE_LIVE=1`) verifies
`import open3d` at startup so a broken image dies on boot instead of 502-ing the
first fuse-capture call (mirrors the rasterio imagery check).

**Two-pass alignment + seed.** Pass 1 is a coarse 0.5 m correspondence basin
(50 iters); pass 2 refines at 0.15 m (30 iters). The init transform matches the
ARKit mesh centroid to the LiDAR centroid (a pure translation): the ARKit origin
is arbitrary and the LiDAR crop is already centred on the building, so the
centroid match is the robust seed. The session GPS origin (re-projected into the
LiDAR UTM frame via pyproj) is used only as a coarse cross-check log, never as
the load-bearing seed — a poor GPS fix therefore can't push the mesh out of the
capture basin. `converged = rmse_m < 0.5 AND fitness > 0.2`. `icp_rmse_m`
reports Open3D's `inlier_rmse` on a good alignment, but falls back to the full
point-cloud RMS distance when fitness is ~0 (a failed alignment has no inliers,
so `inlier_rmse` would otherwise read a misleadingly-tight ~0).

**Additive Measurement model.** Fusion never mutates or re-runs the base
pipeline. On convergence it INSERTS a new `Measurement` row; the newer
`generated_at` makes it win `Job#latest_measurement`, while the original
LiDAR-only row stays as the historical/fallback answer. The job is already
`:ready` when a capture bundle arrives, so `FusionJob`/`FusionOrchestrator`
contain ZERO calls to `advance_to!`/`fail_with!` — touching status would raise
on the terminal guard or corrupt a finished job. All progress feedback is the
SEPARATE `[job, :fusion_status]` Turbo stream. The fused row's
`source_fingerprint` is left `nil` (it isn't the LiDAR-only artifact, so it must
not inherit the prior's idempotency key).

**Confidence formula.** `prior + 0.05 + clamp((0.5 - icp_rmse_m) * 0.1, 0, 0.15)`,
then clamped to `[prior, 1.0]` and rounded to 4 dp — a fused row is never less
confident than the measurement it refines.

**Source mapping.** The sidecar returns `source = "fusion"` (a valid
`GeometrySource` enum) on the embedded Measurement, so `FuseCaptureResponse`
schema-validates with no version bump. Rails maps that to the richer display
string `"lidar+device+imagery"` when persisting the row; `measurements.source`
is a plain varchar with no DB enum constraint.

**Failure isolation.** ICP non-convergence (sidecar returns `measurement: null`,
`icp_rmse_m >= 0.5`) or the lidar-unavailable skip appends an idempotent warning
to the EXISTING measurement and returns nil — no new row, no retry (a re-run
hits the same wall). A sidecar 5xx/transport/timeout/schema error appends a
`fusion_failed` warning and re-raises so the job's bounded
`retry_on StandardError` (3 attempts) can re-attempt a transient blip; the final
attempt records `fusion_job_exhausted`. The job status never changes on any
path.

**Idempotency.** `session_id` is generated once on-device and stable across
upload retries; a unique index on `capture_sessions.session_id` is the guard. A
duplicate ingest POST rescues `RecordNotUnique`/`RecordInvalid`, returns 200 with
the existing session id, and does NOT re-enqueue `FusionJob`. `FusionJob` also
no-ops if the latest measurement is already the fused source (duplicate job
delivery).

**Upload ordering.** The controller uploads every blob (session.json, mesh,
photos, depth maps) to `uploads/<job.id>/` BEFORE persisting any row and BEFORE
enqueuing `FusionJob`, so the sidecar can always fetch every ref by the time the
job runs. `SpacesUploader` is prefix-locked to `uploads/` and streams the IO; in
test/dev it writes to `STORAGE_LOCAL_ROOT` (the same split as the sidecar's
storage.py). The LiDAR `.npy` is loaded with `allow_pickle=False` (a pickled
object array would be an RCE vector) and both the mesh and LiDAR blobs are
size-guarded at 256 MiB; the OBJ parser caps vertices at 5M.

**Known limitations.** The CI ICP test runs on a synthetic gable fixture
(`sidecar/tests/fixtures/f16/`) with a known rigid offset; a real device capture
swaps in as a non-CI validation artifact when available. The synthetic LiDAR
fixture is in a local metric frame, so the fused measurement's WGS84 facet
vertices are only meaningful when the LiDAR cloud is genuinely UTM-projected (as
it is in production).
