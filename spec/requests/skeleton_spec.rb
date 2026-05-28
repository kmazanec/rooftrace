require "rails_helper"

RSpec.describe "GET /skeleton", type: :request do
  # This spec exercises the *real* Rails → sidecar → Postgres round-trip.
  # The sidecar runs as a uvicorn subprocess booted by spec/support/real_sidecar.rb;
  # in CI it runs as a sibling docker-compose service. Either way, no mocks.

  it "round-trips through the sidecar and persists a SkeletonPing row" do
    expect { get "/skeleton" }.to change(SkeletonPing, :count).by(1)

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)

    expect(body["ping_id"]).to be_present
    expect(body["job_id"]).to match(/\A[0-9a-f-]{36}\z/)
    expect(body["sidecar_response"]).to include(
      "echo_payload" => "hello from sidecar",
      "sidecar_version" => "0.1.0"
    )
    expect(body["db_row"]["id"]).to eq(body["ping_id"])

    ping = SkeletonPing.find(body["ping_id"])
    expect(ping.job_id).to eq(body["job_id"])
    expect(ping.rtt_ms).to be >= 0
    expect(ping.sidecar_payload["echo_payload"]).to eq("hello from sidecar")
  end

  it "returns 502 (not a 500 crash) when the sidecar response is malformed" do
    allow(SidecarClient).to receive(:skeleton).and_return("received_at" => "not-a-timestamp")

    expect { get "/skeleton" }.not_to change(SkeletonPing, :count)
    expect(response).to have_http_status(:bad_gateway)
    expect(JSON.parse(response.body)["error"]).to eq("sidecar unavailable")
  end

  it "returns 502 when the sidecar is unreachable" do
    allow(SidecarClient).to receive(:skeleton).and_raise(SidecarClient::TimeoutError, "boom")

    get "/skeleton"
    expect(response).to have_http_status(:bad_gateway)
  end
end
