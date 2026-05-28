require "rails_helper"

# The public, token-gated JSON export (GET /r/:token.json, ADR-015). No login —
# the 32-char share token IS the access grant. A bad token 404s (head, no body
# leak). Sets a permissive CORS header (Access-Control-Allow-Origin: *) so
# browser-based downstream tools can fetch it, and X-Robots-Tag: noindex since
# the share token is a URL-borne bearer credential. Returns the IDENTICAL
# JobExportSerializer output as /api/v1/jobs/:id.json.
RSpec.describe "Public JSON export", type: :request do
  let(:job) { create(:job, address: "1600 Pennsylvania Ave NW", status: "ready") }
  let!(:measurement) do
    create(:measurement, job: job, source: "fusion", confidence: 0.82,
                         total_area_sq_ft: 1200.0, predominant_pitch_ratio: 6.0,
                         facets: [], features: [], generated_at: Time.current)
  end
  let(:report) { create(:report, job: job) }

  it "404s for an unknown token with no body leak" do
    get "/r/#{'Z' * 32}.json"
    expect(response).to have_http_status(:not_found)
    expect(response.body).to be_blank
  end

  it "returns 200 + application/json for a valid token" do
    get "/r/#{report.share_token}.json"
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")
  end

  it "emits a permissive CORS header" do
    get "/r/#{report.share_token}.json"
    expect(response.headers["Access-Control-Allow-Origin"]).to eq("*")
  end

  it "marks the response noindex (share token is a bearer credential)" do
    get "/r/#{report.share_token}.json"
    expect(response.headers["X-Robots-Tag"]).to eq("noindex")
  end

  it "round-trips: parsed body matches the source measurement" do
    get "/r/#{report.share_token}.json"
    body = response.parsed_body
    expect(body["schema_version"]).to eq("1.0.0")
    expect(body.dig("job", "id")).to eq(report.job_id)
    expect(body.dig("measurement", "total_area_sq_ft")).to eq(1200.0)
    expect(body.dig("measurement", "source")).to eq("fusion")
    expect(body.dig("artifacts", "share_url")).to eq("http://www.example.com/r/#{report.share_token}")
  end

  # Frozen barrier resolver: nil job OR nil measurement => 200-with-null-artifacts
  # JSON, NEVER 500. The schema permits a null measurement.
  it "returns 200 with a null measurement when the report's job is not ready" do
    not_ready = create(:job, status: "fetching_imagery")
    report_no_m = create(:report, job: not_ready)
    get "/r/#{report_no_m.share_token}.json"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["measurement"]).to be_nil
  end

  # An orphaned share token (the report's job was destroyed, nullifying job_id
  # via has_many :reports, dependent: :nullify) cannot produce a valid export
  # (the contract requires a non-null job id/status). It must be treated as
  # not-found — NEVER a 500 that would leak schema-validation detail to this
  # anonymous, CORS-open caller.
  it "404s (never 500) when the report's job has been destroyed" do
    orphan = create(:report, job: create(:job))
    orphan.job.destroy
    get "/r/#{orphan.share_token}.json"
    expect(response).to have_http_status(:not_found)
    expect(response.body).to be_blank
  end
end
