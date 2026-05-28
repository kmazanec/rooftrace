require "rails_helper"

# MeasurementOrchestrator unit/integration tests (the F-10 acceptance suite).
#
# The unit under test is the ORCHESTRATION LOGIC, not the wire: SidecarClient and
# FeatureDetector are stubbed. Stage responses are built by PipelineStageFixtures
# and are themselves schema-valid (asserted below), so we're composing realistic
# contract payloads. The signed-URL minter is stubbed so no Spaces/AWS call is
# made.
RSpec.describe MeasurementOrchestrator, type: :service do
  include PipelineStageFixtures

  let(:job) { create(:job) }

  # Stubbed collaborators.
  let(:sidecar) { class_double(SidecarClient) }
  let(:detector) { instance_double(FeatureDetector::Gemini) }
  let(:detector_factory) { class_double(FeatureDetector, build: detector) }
  let(:url_minter) { class_double(ImageryUrlMinter) }

  subject(:orchestrator) do
    described_class.new(job, sidecar: sidecar, detector_factory: detector_factory,
                             url_minter: url_minter)
  end

  # Default happy-path stubs (LiDAR available). Individual examples override.
  def stub_happy_path(lidar_status: "LIDAR_AVAILABLE")
    allow(sidecar).to receive(:resolve_address).and_return(resolve_address_response)
    allow(sidecar).to receive(:render_imagery).and_return(render_imagery_response)
    allow(sidecar).to receive(:ingest_lidar).and_return(ingest_lidar_response(status: lidar_status))
    allow(sidecar).to receive(:refine_outline).and_return(refine_outline_response)
    allow(sidecar).to receive(:fit_planes).and_return(measurement_geometry(source: "fusion"))
    allow(sidecar).to receive(:fallback_measurement)
      .and_return(measurement_geometry(source: "imagery", confidence: 0.7))
    allow(url_minter).to receive(:call).and_return("https://rooftrace.nyc3.digitaloceanspaces.com/cache/imagery/abc123.png")
    allow(detector).to receive(:detect).and_return([ feature ])
  end

  # Capture the raw status-stream broadcasts in order.
  def captured_statuses
    statuses = []
    allow(job).to receive(:advance_to!).and_wrap_original do |orig, status|
      statuses << status.to_s
      orig.call(status)
    end
    statuses
  end

  describe "fixtures are schema-valid" do
    it "every stage fixture validates against its schema entity" do
      expect(PipelineSchema.errors_for("ResolveAddressResponse", resolve_address_response)).to be_empty
      expect(PipelineSchema.errors_for("RenderImageryResponse", render_imagery_response)).to be_empty
      expect(PipelineSchema.errors_for("IngestLidarResponse", ingest_lidar_response)).to be_empty
      expect(PipelineSchema.errors_for("IngestLidarResponse", ingest_lidar_response(status: "LIDAR_MISSING"))).to be_empty
      expect(PipelineSchema.errors_for("RefineOutlineResponse", refine_outline_response)).to be_empty
      expect(PipelineSchema.errors_for("MeasurementGeometry", measurement_geometry)).to be_empty
      expect(PipelineSchema.errors_for("Feature", feature)).to be_empty
    end
  end

  describe "happy path (LiDAR available)" do
    before { stub_happy_path }

    it "persists a fusion Measurement with facets and features, ending ready" do
      measurement = orchestrator.call

      expect(measurement).to be_a(Measurement)
      expect(measurement).to be_persisted
      expect(measurement.source).to eq("fusion")
      expect(measurement.facets).not_to be_empty
      expect(measurement.features).not_to be_empty
      expect(measurement.features.first["label"]).to eq("chimney")
      expect(measurement.footprint).to be_present
      expect(measurement.roof_outline).to be_present
      expect(measurement.lidar["status"]).to eq("LIDAR_AVAILABLE")
      expect(measurement.total_area_sq_ft).to eq(1200.0)
      expect(measurement.predominant_pitch_ratio).to eq(6.0)
      expect(measurement.generated_at).to be_present
      expect(measurement.provenance["detector"]).to eq(FeatureDetector::DETECTOR_NAME)
      expect(measurement.provenance["pipeline_schema_version"]).to eq(PipelineSchema.version)
      expect(job.reload.status).to eq("ready")
    end

    it "persists perimeter, geocode, and parcel polygon onto the row" do
      measurement = orchestrator.call

      expect(measurement.total_perimeter_ft.to_f).to eq(140.0)
      expect(measurement.geocode["normalized"]).to eq("1600 Pennsylvania Ave NW, Washington, DC 20500")
      expect(measurement.geocode["lon"]).to be_within(0.0001).of(-96.70240)
      expect(measurement.parcel_polygon["type"]).to eq("Polygon")
    end

    it "still validates the assembled Measurement document (extra row columns excluded)" do
      # The schema-validated document must not carry the row-only columns
      # (Measurement $def is additionalProperties:false). If it did, validation
      # would raise and the job would fail; reaching :ready proves it didn't.
      expect { orchestrator.call }.not_to raise_error
      expect(job.reload.status).to eq("ready")
    end

    it "tolerates a null parcel polygon" do
      allow(sidecar).to receive(:resolve_address)
        .and_return(resolve_address_response.merge("parcel_polygon" => nil))

      measurement = orchestrator.call

      expect(measurement.parcel_polygon).to be_nil
      expect(measurement.geocode).to be_present
      expect(job.reload.status).to eq("ready")
    end

    it "enriches provenance with the LiDAR work-unit and stage retrieved_at values" do
      measurement = orchestrator.call
      prov = measurement.provenance

      expect(prov.dig("lidar_work_unit", "year")).to eq(2020)
      expect(prov.dig("lidar_work_unit", "quality_level")).to eq("QL2")
      expect(prov["retrieved_at"]).to include("resolve_address" => "2024-06-01T00:00:00Z")
      # Untouched fields are still there.
      expect(prov["sam2_backend"]).to eq("local")
      expect(prov["geometry_source"]).to eq("fusion")
    end

    it "broadcasts status transitions in the documented order" do
      statuses = captured_statuses
      orchestrator.call

      # detecting_features is broadcast when the parallel VLM starts (after
      # imagery), then the geometric stages continue; ready is the final state.
      expect(statuses).to eq(%w[
        resolving_address
        fetching_imagery
        detecting_features
        fetching_lidar
        refining_outline
        fitting_planes
        ready
      ])
    end

    it "broadcasts to the job's raw status stream (one per transition)" do
      # Assert against the raw "<gid>:status" stream F-11 subscribes to (NOT
      # .from_channel, whose broadcasting_for would add a prefix turbo omits).
      expect { orchestrator.call }
        .to have_broadcasted_to("#{job.to_gid_param}:status").exactly(7).times
    end

    it "combines stage confidences (geocode * geometry) for fusion" do
      measurement = orchestrator.call
      # 0.95 (geocode) * 0.9 (geometry) = 0.855
      expect(measurement.confidence.to_f).to be_within(0.0001).of(0.855)
    end
  end

  describe "fallback path (LiDAR missing)" do
    before { stub_happy_path(lidar_status: "LIDAR_MISSING") }

    it "produces an imagery measurement with lower confidence and a lidar_missing warning" do
      measurement = orchestrator.call

      expect(measurement.source).to eq("imagery")
      expect(measurement.warnings).to include(a_string_starting_with("lidar_missing:"))
      # capped to the imagery ceiling (0.6), below the fusion path's 0.855
      expect(measurement.confidence.to_f).to be <= 0.6
      expect(job.reload.status).to eq("ready")
    end

    it "calls fallback_measurement (not fit_planes) with a derived utm zone and inferred pitch" do
      expect(sidecar).to receive(:fallback_measurement).with(
        hash_including(
          inferred_pitch_degrees: MeasurementOrchestrator::DEFAULT_INFERRED_PITCH_DEGREES,
          utm_zone: an_instance_of(Integer)
        )
      ).and_return(measurement_geometry(source: "imagery", confidence: 0.7))
      expect(sidecar).not_to receive(:fit_planes)

      orchestrator.call
    end
  end

  describe "ingest-lidar degradation (ADR-001)" do
    before { stub_happy_path }

    it "degrades to the imagery fallback when ingest-lidar times out" do
      allow(sidecar).to receive(:ingest_lidar)
        .and_raise(SidecarClient::TimeoutError, "Sidecar /ingest-lidar timed out after 90s")
      expect(sidecar).to receive(:fallback_measurement)
        .and_return(measurement_geometry(source: "imagery", confidence: 0.7))
      expect(sidecar).not_to receive(:fit_planes)

      measurement = orchestrator.call

      expect(measurement.source).to eq("imagery")
      expect(measurement.warnings)
        .to include(a_string_starting_with("lidar_unavailable: SidecarClient::TimeoutError"))
      expect(measurement.confidence.to_f).to be <= 0.6
      expect(job.reload.status).to eq("ready")
    end

    it "degrades on a transport SidecarClient::Error from ingest-lidar" do
      allow(sidecar).to receive(:ingest_lidar)
        .and_raise(SidecarClient::Error, "502 bad gateway")

      measurement = orchestrator.call

      expect(measurement.source).to eq("imagery")
      expect(measurement.warnings)
        .to include(a_string_starting_with("lidar_unavailable: SidecarClient::Error"))
      expect(job.reload.status).to eq("ready")
    end

    it "HARD-fails (does not degrade) on a SchemaError from ingest-lidar" do
      allow(sidecar).to receive(:ingest_lidar).and_raise(
        SidecarClient::SchemaError,
        "IngestLidarResponse response validation failed (contract drift?): /lidar: required"
      )
      expect(sidecar).not_to receive(:fallback_measurement)

      result = orchestrator.call

      expect(result).to be_nil
      expect(job.reload.status).to eq("failed")
      expect(job.last_error).to include("ingest-lidar")
      expect(Measurement.where(job: job)).to be_empty
    end
  end

  describe "empty-facets guard" do
    before { stub_happy_path }

    it "fails (no measurement) when fit-planes returns zero facets" do
      allow(sidecar).to receive(:fit_planes)
        .and_return(measurement_geometry(source: "fusion").merge("facets" => []))

      result = orchestrator.call

      expect(result).to be_nil
      expect(job.reload.status).to eq("failed")
      expect(job.last_error).to match(/facet/i)
      expect(Measurement.where(job: job)).to be_empty
    end

    it "fails (no measurement) when the imagery fallback returns zero facets" do
      allow(sidecar).to receive(:ingest_lidar)
        .and_return(ingest_lidar_response(status: "LIDAR_MISSING"))
      allow(sidecar).to receive(:fallback_measurement)
        .and_return(measurement_geometry(source: "imagery", confidence: 0.7).merge("facets" => []))

      result = orchestrator.call

      expect(result).to be_nil
      expect(job.reload.status).to eq("failed")
      expect(job.last_error).to match(/facet/i)
      expect(Measurement.where(job: job)).to be_empty
    end
  end

  describe "UTM zone derivation on the fallback path" do
    before { stub_happy_path(lidar_status: "LIDAR_MISSING") }

    it "fails cleanly (no wrong-zone guess) when the geocode has no longitude" do
      resolve = resolve_address_response
      resolve["geocode"]["lon"] = nil
      allow(sidecar).to receive(:resolve_address).and_return(resolve)
      expect(sidecar).not_to receive(:fallback_measurement)

      result = orchestrator.call

      expect(result).to be_nil
      expect(job.reload.status).to eq("failed")
      expect(job.last_error).to match(/projection|longitude/i)
      expect(Measurement.where(job: job)).to be_empty
    end
  end

  describe "contract-drift handling" do
    before { stub_happy_path }

    it "fails the job naming the offending stage when a stage raises SchemaError" do
      allow(sidecar).to receive(:ingest_lidar).and_raise(
        SidecarClient::SchemaError,
        "IngestLidarResponse response validation failed (contract drift?): /lidar: required"
      )

      result = orchestrator.call

      expect(result).to be_nil
      expect(job.reload.status).to eq("failed")
      expect(job.last_error).to include("ingest-lidar")
      expect(job.last_error).to include("contract violation")
      expect(Measurement.where(job: job)).to be_empty
    end

    it "fails loudly when the assembled Measurement itself violates the schema" do
      # A facet missing required fields makes the assembled Measurement invalid.
      bad_geometry = measurement_geometry.merge(
        "facets" => [ { "facet_id" => "F1" } ]
      )
      allow(sidecar).to receive(:fit_planes).and_return(bad_geometry)

      result = orchestrator.call

      expect(result).to be_nil
      expect(job.reload.status).to eq("failed")
      expect(job.last_error).to match(/Measurement/i)
    end
  end

  describe "VLM failure isolation" do
    before { stub_happy_path }

    it "completes with features:[] + a warning when the detector raises" do
      allow(detector).to receive(:detect).and_raise(
        FeatureDetector::Gemini::VlmTimeout, "Gemini timed out"
      )

      measurement = orchestrator.call

      expect(measurement.source).to eq("fusion")
      expect(measurement.features).to eq([])
      expect(measurement.warnings).to include(a_string_starting_with("vlm_failed:"))
      expect(measurement.facets).not_to be_empty
      expect(job.reload.status).to eq("ready")
    end

    it "still completes when the signed-URL minter itself fails" do
      allow(url_minter).to receive(:call).and_raise(ImageryUrlMinter::Error, "boom")

      measurement = orchestrator.call

      expect(measurement.features).to eq([])
      expect(measurement.warnings).to include(a_string_starting_with("vlm_failed:"))
    end
  end

  describe "geometric failure fails the whole job" do
    it "fails when no building polygon is found, persisting no measurement" do
      allow(sidecar).to receive(:resolve_address)
        .and_return(resolve_address_response.merge("building_polygons" => []))

      # render_imagery etc. should never be called.
      expect(sidecar).not_to receive(:render_imagery)

      result = orchestrator.call

      expect(result).to be_nil
      expect(job.reload.status).to eq("failed")
      expect(job.last_error).to match(/building footprint/i)
      expect(Measurement.where(job: job)).to be_empty
    end

    it "fails when resolve_address raises a sidecar error" do
      allow(sidecar).to receive(:resolve_address).and_raise(SidecarClient::Error, "502 bad gateway")

      result = orchestrator.call

      expect(result).to be_nil
      expect(job.reload.status).to eq("failed")
      expect(Measurement.where(job: job)).to be_empty
    end
  end

  describe "polygon selection" do
    before { stub_happy_path }

    it "clamps an out-of-range polygon_selection to the first polygon" do
      job.update!(polygon_selection: 99)
      allow(sidecar).to receive(:resolve_address)
        .and_return(resolve_address_response(building_count: 2))

      expect { orchestrator.call }.not_to raise_error
      expect(job.reload.status).to eq("ready")
    end
  end

  describe "idempotency" do
    before { stub_happy_path }

    it "reuses a measurement generated within the last hour without re-running" do
      first = orchestrator.call
      expect(first).to be_persisted

      # A fresh orchestrator over the same job must not touch the sidecar again.
      second_sidecar = class_double(SidecarClient)
      expect(second_sidecar).not_to receive(:resolve_address)
      second = described_class.new(job, sidecar: second_sidecar,
                                        detector_factory: detector_factory,
                                        url_minter: url_minter).call

      expect(second.id).to eq(first.id)
      expect(Measurement.where(job: job).count).to eq(1)
    end

    it "re-runs when the latest measurement is older than the window" do
      first = orchestrator.call
      first.update!(generated_at: 2.hours.ago)

      second = described_class.new(job, sidecar: sidecar, detector_factory: detector_factory,
                                        url_minter: url_minter).call

      expect(second.id).not_to eq(first.id)
      expect(Measurement.where(job: job).count).to eq(2)
    end

    it "does not reuse a fresh measurement whose inputs no longer match (address edit)" do
      first = orchestrator.call
      expect(first).to be_persisted

      # Simulate an address edit on the same Job: the cached measurement is
      # within the window but its input fingerprint no longer matches.
      job.update!(address: "742 Evergreen Terrace, Springfield")

      second = described_class.new(job, sidecar: sidecar, detector_factory: detector_factory,
                                        url_minter: url_minter).call

      expect(second.id).not_to eq(first.id)
      expect(Measurement.where(job: job).count).to eq(2)
    end

    it "reuses only when the fingerprint matches the current address+polygon_selection" do
      first = orchestrator.call

      # polygon_selection edit also invalidates the cache hit.
      job.update!(polygon_selection: 1)

      second = described_class.new(job, sidecar: sidecar, detector_factory: detector_factory,
                                        url_minter: url_minter).call

      expect(second.id).not_to eq(first.id)
    end
  end
end
