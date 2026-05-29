require "rails_helper"
require "webmock/rspec"

# SidecarClient#fuse_capture contract test (ADR-007 capture-bundle fusion,
# ADR-008 Rails↔sidecar boundary). Proves:
#   - the FuseCaptureRequest payload it builds validates against the schema
#   - it POSTs to /pipeline/fuse-capture with the right timeout
#   - it parses + validates a FuseCaptureResponse from both the converged
#     (full Measurement) and non-converged (no measurement) fixtures
#
# WebMock disables non-localhost connections; localhost is re-allowed in
# spec/support/webmock.rb so the real-sidecar specs keep working.
RSpec.describe SidecarClient, type: :service do
  let(:secret) { "test-shared-secret" }
  let(:base)   { "http://127.0.0.1:19999" }
  let(:client) { described_class.new(base_url: base, shared_secret: secret) }

  let(:path) { "/pipeline/fuse-capture" }
  let(:job_id) { "11111111-1111-4111-8111-111111111111" }
  let(:capture_mesh_ref) { "uploads/#{job_id}/arkit_mesh.obj" }
  let(:lidar) do
    {
      "status" => "LIDAR_AVAILABLE",
      "point_array_ref" => "cache/#{job_id}/points.npy",
      "point_count" => 48_213,
      "source" => "lidar",
      "confidence" => 0.95
    }
  end

  def fixture(name)
    JSON.parse(File.read(Rails.root.join("spec", "fixtures", "pipeline", name)))
  end

  let(:response_valid)          { fixture("fuse_capture_response.valid.json")["payload"] }
  let(:response_no_measurement) { fixture("fuse_capture_response.no_measurement.valid.json")["payload"] }

  def stub_sidecar(response_body, status: 200)
    stub_request(:post, "#{base}#{path}")
      .to_return(
        status: status,
        body: response_body.is_a?(String) ? response_body : response_body.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  describe "#fuse_capture request contract" do
    it "builds a FuseCaptureRequest payload that validates against the schema" do
      payload = {
        "pipelineSchemaVersion" => PipelineSchema.version,
        "job_id" => job_id,
        "capture_mesh_ref" => capture_mesh_ref,
        "lidar" => lidar
      }
      expect(PipelineSchema.errors_for("FuseCaptureRequest", payload)).to be_empty
    end

    it "omits lidar from the payload when it is nil and still validates" do
      payload = {
        "pipelineSchemaVersion" => PipelineSchema.version,
        "job_id" => job_id,
        "capture_mesh_ref" => capture_mesh_ref
      }
      expect(PipelineSchema.errors_for("FuseCaptureRequest", payload)).to be_empty
    end

    it "sends a schema-valid request body to the sidecar including lidar" do
      stub_sidecar(response_valid)
      client.fuse_capture(job_id: job_id, capture_mesh_ref: capture_mesh_ref, lidar: lidar)

      expect(
        a_request(:post, "#{base}#{path}").with(headers: { "Authorization" => "Bearer #{secret}" }) do |req|
          body = JSON.parse(req.body)
          PipelineSchema.errors_for("FuseCaptureRequest", body).empty? &&
            body["capture_mesh_ref"].end_with?("/arkit_mesh.obj") &&
            body["lidar"] == lidar
        end
      ).to have_been_made.once
    end

    it "does not include a lidar key when lidar is nil" do
      stub_sidecar(response_valid)
      client.fuse_capture(job_id: job_id, capture_mesh_ref: capture_mesh_ref)

      expect(
        a_request(:post, "#{base}#{path}") do |req|
          !JSON.parse(req.body).key?("lidar")
        end
      ).to have_been_made.once
    end
  end

  describe "#fuse_capture timeout + path" do
    it "posts to /pipeline/fuse-capture with the 120s default timeout" do
      stub_sidecar(response_valid)
      expect(client).to receive(:post_json)
        .with("/pipeline/fuse-capture", an_instance_of(Hash),
              timeout: described_class::FUSE_CAPTURE_TIMEOUT_SECONDS)
        .and_return(response_valid)
      client.fuse_capture(job_id: job_id, capture_mesh_ref: capture_mesh_ref, lidar: lidar)
    end

    it "honors an explicit timeout override" do
      expect(client).to receive(:post_json)
        .with("/pipeline/fuse-capture", an_instance_of(Hash), timeout: 5)
        .and_return(response_valid)
      client.fuse_capture(job_id: job_id, capture_mesh_ref: capture_mesh_ref, timeout: 5)
    end

    it "FUSE_CAPTURE_TIMEOUT_SECONDS is 120" do
      expect(described_class::FUSE_CAPTURE_TIMEOUT_SECONDS).to eq(120)
    end
  end

  describe "#fuse_capture response contract" do
    it "returns the parsed converged response with a full Measurement" do
      stub_sidecar(response_valid)
      result = client.fuse_capture(job_id: job_id, capture_mesh_ref: capture_mesh_ref, lidar: lidar)

      expect(result["measurement"]).to be_a(Hash)
      expect(result["measurement"]["source"]).to eq("fusion")
      expect(result["icp_rmse_m"]).to eq(0.05)
      expect(PipelineSchema.errors_for("FuseCaptureResponse", result)).to be_empty
    end

    it "returns the non-converged response with no measurement" do
      stub_sidecar(response_no_measurement)
      result = client.fuse_capture(job_id: job_id, capture_mesh_ref: capture_mesh_ref, lidar: lidar)

      expect(result).not_to have_key("measurement")
      expect(result["icp_rmse_m"]).to eq(0.62)
      expect(PipelineSchema.errors_for("FuseCaptureResponse", result)).to be_empty
    end

    it "raises SchemaError when the sidecar returns a contract-violating response" do
      stub_sidecar({ "pipelineSchemaVersion" => PipelineSchema.version }) # missing job_id
      expect do
        client.fuse_capture(job_id: job_id, capture_mesh_ref: capture_mesh_ref)
      end.to raise_error(SidecarClient::SchemaError, /FuseCaptureResponse/)
    end
  end

  describe ".fuse_capture class shortcut" do
    it "delegates to a new instance" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SIDECAR_URL").and_return(base)
      allow(ENV).to receive(:[]).with("SIDECAR_SHARED_SECRET").and_return(secret)
      stub_sidecar(response_valid)

      result = described_class.fuse_capture(job_id: job_id, capture_mesh_ref: capture_mesh_ref, lidar: lidar)
      expect(result["icp_rmse_m"]).to eq(0.05)
    end
  end
end
