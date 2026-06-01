require "rails_helper"

RSpec.describe "Api::V1 jobs create", type: :request do
  def authorization(app_token)
    { "Authorization" => "Bearer #{app_token.token}" }
  end

  let(:app_token) { AppToken.create! }

  it "creates a job and returns the capture handoff" do
    expect {
      post "/api/v1/jobs",
           params: { address: "742 Evergreen Terrace, Springfield, IL" },
           headers: authorization(app_token),
           as: :json
    }.to change(Job, :count).by(1)
      .and have_enqueued_job(GeometryJob)

    expect(response).to have_http_status(:created)
    job = Job.last
    expect(response.parsed_body).to eq(
      "job_id" => job.id,
      "capture_token" => job.capture_token,
      "capture_token_expires_at" => job.capture_token_expires_at.iso8601
    )
  end

  it "returns 422 for a blank address" do
    post "/api/v1/jobs",
         params: { address: "" },
         headers: authorization(app_token),
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["errors"]).to include("Address can't be blank")
  end

  it "returns 401 without a bearer" do
    post "/api/v1/jobs", params: { address: "123 Main St" }, as: :json

    expect(response).to have_http_status(:unauthorized)
  end
end
