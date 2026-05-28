require "rails_helper"

RSpec.describe "iOS capture sessions", type: :request do
  let(:job) { create(:job) }

  def post_capture(job_id, token)
    headers = token ? { "Authorization" => "Bearer #{token}" } : {}
    post api_v1_capture_session_path(job_id: job_id), headers: headers
  end

  it "accepts a request with a valid job-scoped capture token (200)" do
    post_capture(job.id, job.capture_token)
    expect(response).to have_http_status(:ok)
  end

  it "rejects a missing bearer token (401)" do
    post_capture(job.id, nil)
    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects a wrong token (401)" do
    post_capture(job.id, "Q" * 32)
    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects a bare 'Bearer ' with no token (401)" do
    post api_v1_capture_session_path(job_id: job.id), headers: { "Authorization" => "Bearer " }
    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects an expired token (401) with a clear error" do
    job.update_column(:capture_token_expires_at, 1.minute.ago)
    post_capture(job.id, job.capture_token)
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body["error"]).to match(/expired|invalid/i)
  end

  it "rejects a valid token used against a different job's URL (token is job-scoped)" do
    other = create(:job)
    post_capture(other.id, job.capture_token)
    expect(response).to have_http_status(:unauthorized)
  end

  it "never requires the dev-login session" do
    # No session set; a valid bearer alone is sufficient.
    post_capture(job.id, job.capture_token)
    expect(response).to have_http_status(:ok)
  end
end

RSpec.describe "Job creation returns the capture credential", type: :request do
  around do |example|
    ENV["DEMO_USERNAME"] = "demo"
    ENV["DEMO_PASSWORD_DIGEST"] = BCrypt::Password.create("pw")
    example.run
  end

  def login!
    post login_path, params: { username: "demo", password: "pw" }
  end

  it "returns {job_id, capture_token, capture_token_expires_at} to a JSON client" do
    login!
    post jobs_path, params: { job: { address: "123 Main St" } }, as: :json
    expect(response).to have_http_status(:created)
    body = response.parsed_body
    expect(body["job_id"]).to be_present
    expect(body["capture_token"]).to match(%r{\A[1-9A-HJ-NP-Za-km-z]{32}\z})
    expect(body["capture_token_expires_at"]).to be_present
  end

  it "redirects a browser form submit to the job status page (not raw JSON)" do
    login!
    post jobs_path, params: { job: { address: "123 Main St" } }
    expect(response).to have_http_status(:found)
    # F-11: create now redirects to the job status page, not back to the form.
    job = Job.last
    expect(response).to redirect_to(job_path(job))
  end
end
