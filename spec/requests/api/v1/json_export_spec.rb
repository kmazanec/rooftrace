require "rails_helper"

# The auth-required contractor JSON export (GET /api/v1/jobs/:id.json, ADR-015).
# Unlike the HTML surfaces this returns 401 — NOT a 302 redirect — when
# unauthenticated, so downstream tools (which don't follow redirects) fail
# cleanly. It is locked down: NO CORS header (that's only for the public share
# route). Returns the IDENTICAL JobExportSerializer output as /r/:token.json.
RSpec.describe "Api::V1 JSON export", type: :request do
  let(:username) { "demo" }
  let(:password) { "correct-horse" }

  around do |example|
    ENV["DEMO_USERNAME"] = username
    ENV["DEMO_PASSWORD_DIGEST"] = BCrypt::Password.create(password)
    example.run
  end

  def login!
    post login_path, params: { username: username, password: password }
  end

  let(:job) { create(:job, address: "1600 Pennsylvania Ave NW", status: "ready") }
  let!(:measurement) do
    create(:measurement, job: job, source: "fusion", confidence: 0.82,
                         total_area_sq_ft: 1200.0, predominant_pitch_ratio: 6.0,
                         facets: [ { "facet_id" => "F1",
                                     "vertices" => [ [ -77.0, 38.0 ], [ -77.1, 38.1 ], [ -77.2, 38.2 ] ],
                                     "pitch_ratio" => 6.0, "area_sq_ft" => 600.0,
                                     "source" => "fusion", "confidence" => 0.8 } ],
                         features: [], generated_at: Time.current)
  end

  describe "unauthenticated" do
    it "returns 401 (NOT a 302 redirect) with no Location header" do
      get "/api/v1/jobs/#{job.id}.json"
      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["Location"]).to be_nil
    end
  end

  describe "authenticated" do
    before { login! }

    it "returns 200 + a top-level JSON export object with the locked field naming" do
      get "/api/v1/jobs/#{job.id}.json"
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/json")

      body = response.parsed_body
      expect(body["schema_version"]).to eq("1.1.0")
      expect(body.keys).to include("schema_version", "job", "measurement", "provenance", "artifacts")
      expect(body.dig("job", "id")).to eq(job.id)

      facet = body.dig("measurement", "facets", 0)
      expect(facet).to have_key("area_sq_ft")
      expect(facet["pitch_ratio"]).to eq(6.0)
      expect(body.dig("measurement", "predominant_pitch_degrees")).to be_a(Numeric)
    end

    it "emits NO Access-Control-Allow-Origin header (auth route is locked down)" do
      get "/api/v1/jobs/#{job.id}.json"
      expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
    end

    # Frozen barrier resolver: nil measurement => 200-with-null-artifacts JSON,
    # NEVER 500 / 404. The schema permits a null measurement.
    it "returns 200 with a null measurement when the job is not ready" do
      not_ready = create(:job, status: "fetching_imagery")
      get "/api/v1/jobs/#{not_ready.id}.json"
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["measurement"]).to be_nil
      expect(body.dig("artifacts", "pdf_url")).to be_nil
    end

    it "returns 404 for an unknown job id" do
      get "/api/v1/jobs/#{SecureRandom.uuid}.json"
      expect(response).to have_http_status(:not_found)
    end

    # Public-share identity is part of the export payload, so the auth and public
    # routes must agree on it: a job WITH a report exports the same canonical
    # share_url on both routes (the frozen identical-output rule).
    it "injects the same artifacts.share_url the public route does, for a job with a report" do
      report = create(:report, job: job)

      get "/api/v1/jobs/#{job.id}.json"
      auth_share_url = response.parsed_body.dig("artifacts", "share_url")

      get "/r/#{report.share_token}.json"
      public_share_url = response.parsed_body.dig("artifacts", "share_url")

      expect(auth_share_url).to eq("http://www.example.com/r/#{report.share_token}")
      expect(auth_share_url).to eq(public_share_url)
    end

    it "leaves artifacts.share_url null when the job has no report" do
      get "/api/v1/jobs/#{job.id}.json"
      expect(response.parsed_body.dig("artifacts", "share_url")).to be_nil
    end
  end
end
