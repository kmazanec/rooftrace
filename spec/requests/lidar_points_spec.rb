require "rails_helper"

# Request-level coverage for the LiDAR point-cloud overlay endpoints (ADR-013):
#   - contractor GET /jobs/:id/report/lidar_points (login-gated)
#   - public     GET /r/:token/lidar_points (token-gated, 404 on bad token)
# The sidecar is internal-only, so the browser fetches points THROUGH Rails. The
# SidecarClient call is stubbed here (its own round-trip is covered in
# spec/services/sidecar_client_spec.rb); these specs assert the proxy + the
# never-5xx degrade posture from LidarPointsResponder.
RSpec.describe "LiDAR points overlay", type: :request do
  let(:username) { "demo" }
  let(:password) { "correct-horse" }
  let(:digest)   { BCrypt::Password.create(password) }

  around do |example|
    ENV["DEMO_USERNAME"] = username
    ENV["DEMO_PASSWORD_DIGEST"] = digest
    example.run
  end

  def login!
    post login_path, params: { username: username, password: password }
  end

  let(:sidecar_body) do
    {
      "pipelineSchemaVersion" => PipelineSchema.version,
      "points" => [ [ -89.6502, 39.7990, 1082.5 ], [ -89.6501, 39.7991, 1083.1 ] ],
      "point_count" => 5213,
      "returned_count" => 2,
      "bounds" => [ -89.6502, 39.7990, -89.6501, 39.7991 ]
    }
  end

  def stub_sidecar_ok
    fake = instance_double(SidecarClient, lidar_points: sidecar_body)
    allow(SidecarClient).to receive(:new).and_return(fake)
    fake
  end

  describe "contractor GET /jobs/:id/report/lidar_points" do
    let(:job) { create(:job, address: "123 Main St") }

    before { login! }

    it "proxies the sidecar points for a LiDAR-backed measurement" do
      create(:measurement, :with_geometry, :with_lidar, job: job)
      fake = stub_sidecar_ok

      get lidar_points_job_path(job)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["returned_count"]).to eq(2)
      expect(body["points"].length).to eq(2)
      expect(fake).to have_received(:lidar_points).with(
        point_array_ref: "cache/lidar/9f2c1ab3.npy",
        building_polygon: kind_of(Hash)
      )
    end

    it "returns empty points (200, not 5xx) when the measurement has no LiDAR" do
      create(:measurement, :with_geometry, job: job) # imagery-only, no :with_lidar
      expect(SidecarClient).not_to receive(:new)

      get lidar_points_job_path(job)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["points"]).to eq([])
      expect(body["reason"]).to eq("lidar_unavailable")
    end

    it "degrades to empty points (200) when the sidecar errors" do
      create(:measurement, :with_geometry, :with_lidar, job: job)
      fake = instance_double(SidecarClient)
      allow(fake).to receive(:lidar_points).and_raise(SidecarClient::Error, "boom")
      allow(SidecarClient).to receive(:new).and_return(fake)

      get lidar_points_job_path(job)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["points"]).to eq([])
      expect(body["reason"]).to eq("lidar_unavailable")
    end

    it "requires login" do
      create(:measurement, :with_geometry, :with_lidar, job: job)
      # Drop the session by hitting logout first.
      delete logout_path
      get lidar_points_job_path(job)
      expect(response).to have_http_status(:found) # redirect to login
    end
  end

  describe "app GET /api/v1/jobs/:id/lidar_points" do
    let(:app_token) { AppToken.create! }
    let(:job) { create(:job, address: "123 Main St") }

    def auth
      { "Authorization" => "Bearer #{app_token.token}" }
    end

    it "proxies the sidecar points for a LiDAR-backed measurement" do
      create(:measurement, :with_geometry, :with_lidar, job: job)
      fake = stub_sidecar_ok

      get api_v1_job_lidar_points_path(id: job.id), headers: auth

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["returned_count"]).to eq(2)
      expect(body["points"].length).to eq(2)
      expect(fake).to have_received(:lidar_points).with(
        point_array_ref: "cache/lidar/9f2c1ab3.npy",
        building_polygon: kind_of(Hash)
      )
    end

    it "returns empty points (200, not 5xx) when the measurement has no LiDAR" do
      create(:measurement, :with_geometry, job: job)
      expect(SidecarClient).not_to receive(:new)

      get api_v1_job_lidar_points_path(id: job.id), headers: auth

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["reason"]).to eq("lidar_unavailable")
    end

    it "degrades to empty points (200) when the sidecar errors" do
      create(:measurement, :with_geometry, :with_lidar, job: job)
      fake = instance_double(SidecarClient)
      allow(fake).to receive(:lidar_points).and_raise(SidecarClient::Error, "boom")
      allow(SidecarClient).to receive(:new).and_return(fake)

      get api_v1_job_lidar_points_path(id: job.id), headers: auth

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["reason"]).to eq("lidar_unavailable")
    end

    it "returns 404 for an unknown job id" do
      get api_v1_job_lidar_points_path(id: SecureRandom.uuid), headers: auth
      expect(response).to have_http_status(:not_found)
    end

    it "401s (not a redirect) without a valid app bearer" do
      create(:measurement, :with_geometry, :with_lidar, job: job)
      get api_v1_job_lidar_points_path(id: job.id)
      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["Location"]).to be_nil
    end
  end

  describe "public GET /r/:token/lidar_points" do
    let(:report) { create(:report) }

    it "proxies the sidecar points for a LiDAR-backed measurement (no login)" do
      create(:measurement, :with_geometry, :with_lidar, job: report.job)
      stub_sidecar_ok

      get public_report_lidar_points_path(token: report.share_token)

      expect(response).to have_http_status(:ok)
      expect(response.headers["X-Robots-Tag"]).to eq("noindex")
      body = JSON.parse(response.body)
      expect(body["returned_count"]).to eq(2)
    end

    it "returns 404 for an unknown token (never leaks the gated app)" do
      get public_report_lidar_points_path(token: "Z" * 32)
      expect(response).to have_http_status(:not_found)
    end

    it "returns empty points when the shared report has no LiDAR measurement" do
      create(:measurement, :with_geometry, job: report.job)

      get public_report_lidar_points_path(token: report.share_token)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["reason"]).to eq("lidar_unavailable")
    end
  end
end
