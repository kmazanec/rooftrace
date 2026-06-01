require "rails_helper"

RSpec.describe "Api::V1 jobs show", type: :request do
  def authorization(app_token)
    { "Authorization" => "Bearer #{app_token.token}" }
  end

  let(:app_token) { AppToken.create! }

  it "returns the current job status shape" do
    job = create(:job, address: "1600 Pennsylvania Ave NW", status: "ready")
    report = create(:report, job: job)

    get "/api/v1/jobs/#{job.id}", headers: authorization(app_token)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "id" => job.id,
      "address" => job.address,
      "status" => "ready",
      "last_error" => nil,
      "ready" => true,
      "share_token" => report.share_token
    )
    expect(Time.iso8601(response.parsed_body.fetch("created_at"))).to be_within(1.second).of(job.created_at)
  end

  it "includes last_error for failed jobs" do
    job = create(:job, status: "failed", last_error: "Sidecar returned 422")

    get "/api/v1/jobs/#{job.id}", headers: authorization(app_token)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["last_error"]).to eq("Sidecar returned 422")
  end

  it "returns 404 for an unknown job id" do
    get "/api/v1/jobs/#{SecureRandom.uuid}", headers: authorization(app_token)

    expect(response).to have_http_status(:not_found)
  end

  it "returns 401 instead of redirecting when the bearer is missing, expired, or garbage" do
    job = create(:job)

    get "/api/v1/jobs/#{job.id}"
    expect(response).to have_http_status(:unauthorized)
    expect(response.headers["Location"]).to be_nil

    get "/api/v1/jobs/#{job.id}", headers: { "Authorization" => "Bearer garbage" }
    expect(response).to have_http_status(:unauthorized)

    expired = AppToken.create!(expires_at: 1.second.ago)
    get "/api/v1/jobs/#{job.id}", headers: authorization(expired)
    expect(response).to have_http_status(:unauthorized)
  end
end
