require "rails_helper"

RSpec.describe "Api::V1 JSON export bearer auth", type: :request do
  def authorization(app_token)
    { "Authorization" => "Bearer #{app_token.token}" }
  end

  let(:app_token) { AppToken.create! }
  let(:job) { create(:job, address: "1600 Pennsylvania Ave NW", status: "ready") }

  before do
    create(:measurement, :with_geometry, job: job)
  end

  it "allows a valid app bearer" do
    get "/api/v1/jobs/#{job.id}.json", headers: authorization(app_token)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("job", "id")).to eq(job.id)
  end

  it "keeps session access working" do
    ENV["DEMO_USERNAME"] = "demo"
    ENV["DEMO_PASSWORD_DIGEST"] = BCrypt::Password.create("correct-horse")

    post login_path, params: { username: "demo", password: "correct-horse" }
    get "/api/v1/jobs/#{job.id}.json"

    expect(response).to have_http_status(:ok)
  end

  it "matches the public export body byte-for-byte" do
    report = create(:report, job: job)

    get "/api/v1/jobs/#{job.id}.json", headers: authorization(app_token)
    bearer_body = response.body

    get "/r/#{report.share_token}.json"
    public_body = response.body

    expect(bearer_body).to eq(public_body)
  end

  it "returns 401 instead of redirecting for bad bearer auth with no session" do
    get "/api/v1/jobs/#{job.id}.json", headers: { "Authorization" => "Bearer garbage" }

    expect(response).to have_http_status(:unauthorized)
    expect(response.headers["Location"]).to be_nil
  end

  it "returns 200 with null measurement for a ready job with no measurement" do
    no_measurement = create(:job, status: "ready")

    get "/api/v1/jobs/#{no_measurement.id}.json", headers: authorization(app_token)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["measurement"]).to be_nil
  end
end
