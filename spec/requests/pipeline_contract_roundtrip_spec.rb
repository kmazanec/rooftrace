require "rails_helper"

# The contract round-trip integration test (no mocks, real sidecar subprocess):
# Rails serializes a fixture PipelineRequest -> POSTs to the REAL sidecar
# subprocess's /pipeline/run-validate -> sidecar validates it against its
# Pydantic models and returns a PipelineResponse -> Rails validates that response
# green against shared/pipeline_schema.json. This proves the two language views
# of the contract agree across the actual IPC boundary.
#
# Skips itself when SKIP_REAL_SIDECAR=1 (the real sidecar isn't booted then).
RSpec.describe "Pipeline contract round-trip", type: :request do
  before do
    skip "real sidecar not booted (SKIP_REAL_SIDECAR=1)" if ENV["SKIP_REAL_SIDECAR"] == "1"
  end

  let(:request_fixture) do
    JSON.parse(Rails.root.join("spec/fixtures/pipeline/pipeline_request.valid.json").read)
  end

  it "round-trips a PipelineRequest and validates the PipelineResponse green" do
    request_payload = request_fixture.fetch("payload")
    expect(PipelineSchema.errors_for("PipelineRequest", request_payload)).to be_empty

    response = SidecarClient.run_validate(request_payload)

    expect(response["status"]).to eq("OK")
    expect(response["job_id"]).to eq(request_payload.dig("job", "job_id"))
    expect(response["pipelineSchemaVersion"]).to eq(PipelineSchema.version)
    expect(PipelineSchema.errors_for("PipelineResponse", response))
      .to(be_empty, "sidecar response failed Rails-side schema validation")
  end

  it "raises when the sidecar rejects a malformed request body" do
    bad = { "pipelineSchemaVersion" => "0.1.0", "job" => { "job_id" => "x" } }
    expect { SidecarClient.run_validate(bad) }.to raise_error(SidecarClient::Error)
  end
end
