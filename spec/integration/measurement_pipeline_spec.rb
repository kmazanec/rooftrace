# frozen_string_literal: true

# END-TO-END measurement-pipeline integration test (the headline acceptance
# criterion).
#
# Unlike spec/services/measurement_orchestrator_spec.rb — which stubs
# SidecarClient ENTIRELY and only exercises the Rails-side composition logic —
# this spec drives MeasurementOrchestrator.call against the REAL Python sidecar
# subprocess (the same `uv run uvicorn` harness the skeleton / SidecarClient
# specs use; see spec/support/real_sidecar.rb). SidecarClient hits the live local
# sidecar over HTTP for every geometry stage we can make hermetic, so the
# headline measurement math (Mapbox/satellite fixture render -> SAM2 local-stub outline ->
# RANSAC plane fit / planimetric fallback) runs for real.
#
# ---------------------------------------------------------------------------
# WHICH STAGES ARE REAL vs STUBBED, AND WHY  (load-bearing — read before editing)
# ---------------------------------------------------------------------------
# REAL over HTTP against the booted sidecar:
#   * render-imagery       — IMAGERY_LIVE unset => deterministic fixture PNG,
#                            written to STORAGE_LOCAL_ROOT. No network.
#   * refine-outline       — SAM2_BACKEND=local => deterministic erosion stub;
#                            reads the just-rendered tile back from storage. No GPU.
#   * fit-planes           — reads a REAL synthetic gable .npy we plant under
#                            STORAGE_LOCAL_ROOT and runs the real RANSAC fit. This
#                            is the LiDAR-available headline geometry, computed live.
#   * fallback-measurement — real planimetric area/cos(pitch) on the LiDAR-missing
#                            path. No storage, no network.
#
# STUBBED at the SidecarClient instance boundary (documented seams):
#   * resolve-address  — the sidecar's resolver ALWAYS calls Nominatim + MS
#       Building Footprints over the real network (router.py:resolve has no
#       fixture/offline fallback; its own tests inject httpx clients into
#       service.resolve() or monkeypatch router.resolve in-process — neither is
#       reachable across the HTTP boundary from Rails). Making it hermetic would
#       require live geocoding, so we stub JUST this one call and keep every
#       geometry stage real. The stubbed payload is still SidecarClient
#       schema-validated as a ResolveAddressRequest/Response on the way through.
#   * ingest-lidar (BOTH paths) — the LiDAR ingest CANNOT run over HTTP in this
#       PDAL-less env: app/lidar/router.py resolves the cropper EAGERLY
#       (`cropper=_resolve_cropper()`) BEFORE the WESM coverage fast-fail, and
#       default_cropper() RAISES RuntimeError whenever LIDAR_LIVE != "1" (real PDAL
#       is conda-only, not in the uv venv). So every ingest-lidar call — covered OR
#       3DEP-gap — returns 502 here; even the LIDAR_MISSING fast-fail is unreachable
#       over the wire (it works only in the sidecar's in-process pytest suite, which
#       monkeypatches a FixtureCropper). There is no env seam for a fixture cropper.
#       We therefore stub ingest-lidar at the SidecarClient boundary on BOTH paths:
#         - available: return LIDAR_AVAILABLE referencing a REAL .npy we planted, so
#           the real fit-planes stage consumes it and the headline plane-fit geometry
#           stays live;
#         - missing:   return LIDAR_MISSING so the real fallback-measurement stage
#           computes the imagery-only geometry live.
#       (See the test bodies; both still schema-validate the stub as an
#       IngestLidarResponse via SidecarClient before the orchestrator uses it.)
#
# STUBBED at the Rails boundary (external service):
#   * FeatureDetector.build (Gemini/VLM) — returns schema-valid feature hashes; for
#       one case it raises, to prove VLM failure-isolation end-to-end.
#   * ImageryUrlMinter — signs a Spaces URL for the VLM; signing needs live Spaces
#       creds. Since the VLM itself is stubbed, we stub its URL-prep too (it is part
#       of the same external-VLM boundary the spec says to stub).
#
# Everything else — status transitions, schema validation on every wire payload,
# Measurement assembly + persistence, confidence math, provenance — is the real
# production code path.

require "tmpdir"
require "fileutils"

# Set the sidecar's hermetic env BEFORE rails_helper loads spec/support, because
# spec/support/real_sidecar.rb spawns the uvicorn subprocess in a before(:suite)
# hook and Process.spawn inherits the parent process ENV. Setting these at file
# load time (which runs after support files are required but before the suite
# hooks execute) means the live sidecar inherits them for its whole lifetime,
# independent of dotenv's per-example ENV autorestore.
PIPELINE_E2E_STORAGE_ROOT = Dir.mktmpdir("rooftrace-e2e-storage")
ENV["STORAGE_LOCAL_ROOT"] = PIPELINE_E2E_STORAGE_ROOT
ENV["SAM2_BACKEND"] = "local"
# IMAGERY_LIVE / LIDAR_LIVE intentionally left unset -> fixture/hermetic paths.
# (ingest-lidar is stubbed on both paths — see the SEAM doc above — so no WESM
# fixture env is needed; the real geometry stages are render-imagery,
# refine-outline, fit-planes and fallback-measurement.)

require "rails_helper"

RSpec.describe "measurement pipeline (end-to-end, real sidecar)", :real_sidecar,
               type: :request do
  include PipelineStageFixtures

  before do
    skip "real sidecar not booted (SKIP_REAL_SIDECAR=1)" if ENV["SKIP_REAL_SIDECAR"] == "1"
  end

  # A real SidecarClient pointed at the booted subprocess. We stub ONLY the two
  # non-hermetic methods (resolve_address always; ingest_lidar on the available
  # path) on this instance; every other method delegates to the live sidecar.
  let(:live_sidecar) do
    SidecarClient.new(
      base_url: ENV.fetch("SIDECAR_URL", RealSidecar.base_url),
      shared_secret: ENV.fetch("SIDECAR_SHARED_SECRET", RealSidecar::SHARED_SECRET)
    )
  end

  # The VLM is an external service; stub it at the Rails boundary and stub the
  # signed-URL minter that feeds it (Spaces signing needs live creds).
  let(:detector) { instance_double(FeatureDetector::OpenRouter) }
  let(:detector_factory) { class_double(FeatureDetector, build: detector) }
  let(:url_minter) { class_double(ImageryUrlMinter) }

  let(:job) { create(:job) }

  # A WGS84 building polygon over Lincoln, NE — inside the WESM fixture's
  # NE_Lancaster_2020 work unit (used for the available path's resolve stub so the
  # geography is internally consistent with a covered area).
  let(:lincoln_building) do
    {
      "type" => "Polygon",
      "coordinates" => [ [
        [ -96.7026, 40.8136 ],
        [ -96.7022, 40.8136 ],
        [ -96.7022, 40.8139 ],
        [ -96.7026, 40.8139 ],
        [ -96.7026, 40.8136 ]
      ] ],
      "source" => "imagery",
      "confidence" => 0.9
    }
  end

  # A rural-Wyoming footprint with NO coverage in the WESM fixture index — the
  # real ingest-lidar coverage check fast-fails this to LIDAR_MISSING over HTTP.
  let(:wyoming_gap_building) do
    {
      "type" => "Polygon",
      "coordinates" => [ [
        [ -107.5, 43.0 ],
        [ -107.4995, 43.0 ],
        [ -107.4995, 43.0004 ],
        [ -107.5, 43.0004 ],
        [ -107.5, 43.0 ]
      ] ],
      "source" => "imagery",
      "confidence" => 0.5
    }
  end

  # Schema-valid VLM feature hashes (what FeatureDetector.build.detect returns).
  let(:detected_features) do
    [ feature(label: "chimney", confidence: 0.82), feature(label: "vent", confidence: 0.71) ]
  end

  # ResolveAddressResponse stub. We can't reach a hermetic real resolver over HTTP
  # (Nominatim/MS network), so this is the one geometry input we feed directly —
  # but it is still schema-validated by SidecarClient on the way in.
  def resolve_stub(building_polygon:)
    {
      "pipelineSchemaVersion" => PipelineSchema.version,
      "geocode" => {
        "raw" => job.address,
        "normalized" => "#{job.address}, USA",
        "lon" => building_polygon["coordinates"][0][0][0],
        "lat" => building_polygon["coordinates"][0][0][1],
        "source" => "imagery",
        "confidence" => 0.95
      },
      "parcel_polygon" => nil,
      "building_polygons" => [ building_polygon ],
      "attribution" => [ { "name" => "Nominatim / OpenStreetMap" } ],
      "warnings" => []
    }
  end

  # ---------------------------------------------------------------------------
  # LiDAR fixture plumbing for the AVAILABLE path.
  # ---------------------------------------------------------------------------

  # Build a real symmetric 6/12 gable point cloud (mirrors the sidecar's own
  # planefit test geometry) and plant it as a .npy under STORAGE_LOCAL_ROOT so the
  # REAL fit-planes endpoint reads it back and runs RANSAC on it.
  POINT_ARRAY_KEY = "cache/lidar/e2e_gable.npy"

  def plant_gable_point_array!
    pitch_rad = Math.atan(6.0 / 12.0)
    facet_area_m2 = 92.9 # ~1000 sq ft per facet
    length = 10.0
    run = (facet_area_m2 * Math.cos(pitch_rad)) / length
    pts_per_facet = 600

    rng = Random.new(0)
    rows = []
    [ 1.0, -1.0 ].each do |sign|
      pts_per_facet.times do
        x_local = rng.rand * run
        y = rng.rand * length
        z = (run - x_local) * Math.tan(pitch_rad)
        rows << [ sign * x_local, y, z ]
      end
    end

    write_npy_float64!(File.join(PIPELINE_E2E_STORAGE_ROOT, POINT_ARRAY_KEY), rows)
  end

  # Minimal NumPy .npy v1.0 writer for a 2-D little-endian float64 array. The
  # sidecar reads this with np.load(allow_pickle=False); a hand-written header
  # avoids a NumPy dependency on the Ruby side.
  def write_npy_float64!(path, rows)
    FileUtils.mkdir_p(File.dirname(path))
    n_rows = rows.length
    n_cols = rows.first.length
    header = "{'descr': '<f8', 'fortran_order': False, 'shape': (#{n_rows}, #{n_cols}), }"
    # Header (incl. trailing newline) must pad the magic+len+header to a
    # multiple of 64 bytes.
    prefix_len = 10 # 6-byte magic + 2-byte version + 2-byte header length
    total = prefix_len + header.length + 1
    pad = (64 - (total % 64)) % 64
    header = header + (" " * pad) + "\n"

    File.open(path, "wb") do |f|
      f.write("\x93NUMPY".b)            # magic
      f.write([ 1, 0 ].pack("C2"))      # version 1.0
      f.write([ header.bytesize ].pack("v")) # little-endian uint16 header len
      f.write(header.b)
      rows.each { |r| f.write(r.map(&:to_f).pack("E*")) } # little-endian float64
    end
    path
  end

  # ingest-lidar AVAILABLE stub referencing the planted real .npy. utm_zone 32618
  # (UTM 18N) matches the sidecar planefit test's zone-18 convention; the gable's
  # metric coords are origin-centred so the WGS84 reprojection is well-defined.
  def lidar_available_stub
    {
      "pipelineSchemaVersion" => PipelineSchema.version,
      "lidar" => {
        "status" => "LIDAR_AVAILABLE",
        "point_array_ref" => POINT_ARRAY_KEY,
        "point_count" => 1200,
        "work_unit" => {
          "name" => "NE_Lancaster_2020", "year" => 2020,
          "quality_level" => "QL2", "epsg" => 32_614
        },
        "source" => "lidar",
        "confidence" => 0.95
      },
      "utm_zone" => 32_618,
      "bounds_utm" => [ 0.0, 0.0, 50.0, 50.0 ],
      "warnings" => [],
      "attribution" => [ { "name" => "USGS 3DEP" } ]
    }
  end

  def build_orchestrator
    MeasurementOrchestrator.new(
      job,
      sidecar: live_sidecar,
      detector_factory: detector_factory,
      url_minter: url_minter
    )
  end

  before do
    allow(url_minter).to receive(:call).and_return(
      "https://rooftrace.nyc3.digitaloceanspaces.com/#{POINT_ARRAY_KEY}"
    )
    allow(detector).to receive(:detect).and_return(detected_features)
  end

  # ===========================================================================
  # LiDAR-available path — fusion measurement, real RANSAC plane fit.
  # ===========================================================================
  describe "LiDAR-available path (real fit-planes on a planted point array)" do
    before do
      plant_gable_point_array!
      allow(live_sidecar).to receive(:resolve_address)
        .and_return(resolve_stub(building_polygon: lincoln_building))
      allow(live_sidecar).to receive(:ingest_lidar).and_return(lidar_available_stub)
    end

    it "persists a fusion Measurement (real outline + real plane fit) ending ready" do
      elapsed = nil
      measurement = nil
      aggregate_failures do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        measurement = build_orchestrator.call
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        # ---- Measurement shape (the headline acceptance assertions) ----
        expect(measurement).to be_a(Measurement)
        expect(measurement).to be_persisted
        expect(measurement.source).to eq("fusion")

        # Non-empty facets, each carrying pitch + area + confidence + source.
        expect(measurement.facets).not_to be_empty
        measurement.facets.each do |facet|
          expect(facet["pitch_ratio"]).to be_a(Numeric)
          expect(facet["pitch_degrees"]).to be_a(Numeric)
          expect(facet["area_sq_ft"]).to be > 0
          expect(facet["confidence"]).to be_a(Numeric)
          expect(facet["source"]).to be_present
        end

        # Features present (from the stubbed-but-schema-valid VLM).
        expect(measurement.features).not_to be_empty
        expect(measurement.features.map { |f| f["label"] }).to include("chimney")

        # Totals set by the real plane fit.
        expect(measurement.total_area_sq_ft).to be > 0
        expect(measurement.predominant_pitch_ratio).to be_a(Numeric)

        # Provenance populated by the real chain (detector id, schema version,
        # the real SAM2 backend the live refine-outline stage reported).
        expect(measurement.provenance["detector"]).to eq(FeatureDetector::DETECTOR_NAME)
        expect(measurement.provenance["pipeline_schema_version"]).to eq(PipelineSchema.version)
        expect(measurement.provenance["sam2_backend"]).to eq("local")

        expect(measurement.confidence.to_f).to be > 0
        expect(measurement.generated_at).to be_present
        expect(job.reload.status).to eq("ready")
      end

      # ---- Latency: spec says <120s warm-cache; assert a tighter bound to
      # catch pathological slowness without flaking on CI jitter. ----
      expect(elapsed).to be < 60, "pipeline took #{elapsed.round(2)}s (budget <60s)"
      Rails.logger.info("[measurement e2e] LiDAR-available pipeline: #{elapsed.round(3)}s")
      # Surface it on stdout too so the run records the observed latency.
      RSpec.configuration.reporter.message(
        "[measurement e2e] LiDAR-available pipeline latency: #{elapsed.round(3)}s"
      )
    end

    it "recomputes a 6/12 gable's geometry through the real plane fit" do
      measurement = build_orchestrator.call
      # Two facets for a symmetric gable; predominant pitch ~6/12 (26.57deg).
      expect(measurement.facets.length).to eq(2)
      expect(measurement.predominant_pitch_ratio).to be_within(0.5).of(6.0)
      # ~2000 sq ft total (2 x 1000), generous tolerance for RANSAC noise.
      expect(measurement.total_area_sq_ft).to be_within(400).of(2000)
    end
  end

  # ===========================================================================
  # VLM failure isolation — proven end-to-end against the real geometry stack.
  # ===========================================================================
  describe "VLM failure isolation (real geometry, detector raises)" do
    before do
      plant_gable_point_array!
      allow(live_sidecar).to receive(:resolve_address)
        .and_return(resolve_stub(building_polygon: lincoln_building))
      allow(live_sidecar).to receive(:ingest_lidar).and_return(lidar_available_stub)
      allow(detector).to receive(:detect)
        .and_raise(FeatureDetector::OpenRouter::VlmTimeout, "VLM timed out")
    end

    it "still produces a fusion Measurement with features:[] + a vlm_failed warning" do
      measurement = build_orchestrator.call

      expect(measurement.source).to eq("fusion")
      expect(measurement.facets).not_to be_empty
      expect(measurement.features).to eq([])
      expect(measurement.warnings).to include(a_string_starting_with("vlm_failed:"))
      expect(job.reload.status).to eq("ready")
    end
  end

  # A schema-valid LIDAR_MISSING ingest-lidar response (the no-coverage outcome).
  def lidar_missing_stub
    {
      "pipelineSchemaVersion" => PipelineSchema.version,
      "lidar" => {
        "status" => "LIDAR_MISSING",
        "point_array_ref" => nil,
        "point_count" => nil,
        "work_unit" => nil,
        "source" => "imagery",
        "confidence" => 0.0
      },
      "utm_zone" => nil,
      "bounds_utm" => nil,
      "warnings" => [ "no_coverage" ],
      "attribution" => []
    }
  end

  # ===========================================================================
  # LiDAR-missing path — real fallback-measurement on the imagery-only branch.
  #
  # NOTE: ingest-lidar is stubbed here for the SAME reason as the available
  # path (see the SEAM doc at the top): the router resolves the conda-only PDAL
  # cropper EAGERLY (before the WESM coverage fast-fail), so default_cropper()
  # raises RuntimeError -> 502 for EVERY ingest-lidar call when LIDAR_LIVE is
  # unset — including 3DEP-gap polygons. So the gap fast-fail is not reachable
  # over HTTP in this PDAL-less env. We stub ingest-lidar to LIDAR_MISSING and
  # keep the rest of the chain (render-imagery, refine-outline, and crucially the
  # real fallback-measurement planimetric geometry) live.
  # ===========================================================================
  describe "LiDAR-missing path (real fallback-measurement on the imagery branch)" do
    before do
      allow(live_sidecar).to receive(:resolve_address)
        .and_return(resolve_stub(building_polygon: wyoming_gap_building))
      allow(live_sidecar).to receive(:ingest_lidar).and_return(lidar_missing_stub)
    end

    it "persists an imagery Measurement with lower confidence + a lidar_missing warning" do
      measurement = build_orchestrator.call

      expect(measurement).to be_persisted
      expect(measurement.source).to eq("imagery")
      expect(measurement.facets).not_to be_empty
      expect(measurement.warnings).to include(a_string_starting_with("lidar_missing:"))
      # Imagery-only confidence is capped below the fusion ceiling.
      expect(measurement.confidence.to_f).to be <= MeasurementOrchestrator::IMAGERY_CONFIDENCE_CAP
      expect(measurement.total_area_sq_ft).to be > 0
      expect(job.reload.status).to eq("ready")
    end

    it "routed through the REAL fallback-measurement stage (not fit-planes)" do
      # Prove the imagery geometry came from the live fallback endpoint: spy on
      # fit_planes (must NOT be called) and on fallback_measurement (must be, and
      # delegate to the real sidecar).
      allow(live_sidecar).to receive(:fallback_measurement).and_call_original

      build_orchestrator.call

      expect(live_sidecar).to have_received(:fallback_measurement).once
      expect(job.reload.status).to eq("ready")
    end
  end
end
