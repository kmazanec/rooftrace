require "rails_helper"

RSpec.describe "Api::V1 jobs index", type: :request do
  def authorization(app_token)
    { "Authorization" => "Bearer #{app_token.token}" }
  end

  let(:app_token) { AppToken.create! }

  it "returns the contractor jobs newest first" do
    older = create(:job, address: "1 Old St", status: "pending", created_at: 2.days.ago)
    newer = create(:job, address: "2 New St", status: "ready", created_at: 1.day.ago)
    report = create(:report, job: newer)

    get "/api/v1/jobs", headers: authorization(app_token)

    expect(response).to have_http_status(:ok)
    jobs = response.parsed_body.fetch("jobs")
    expect(jobs.map { |job| job["id"] }).to eq([ newer.id, older.id ])
    expect(jobs.first).to include(
      "id" => newer.id,
      "address" => "2 New St",
      "status" => "ready",
      "ready" => true,
      "share_token" => report.share_token
    )
    expect(Time.iso8601(jobs.first.fetch("created_at"))).to be_within(1.second).of(newer.created_at)
  end

  it "returns 401 instead of redirecting when the bearer is missing or invalid" do
    get "/api/v1/jobs"
    expect(response).to have_http_status(:unauthorized)
    expect(response.headers["Location"]).to be_nil

    get "/api/v1/jobs", headers: { "Authorization" => "Bearer garbage" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns 401 for an expired bearer" do
    expired = AppToken.create!(expires_at: 1.second.ago)

    get "/api/v1/jobs", headers: authorization(expired)

    expect(response).to have_http_status(:unauthorized)
  end
end
