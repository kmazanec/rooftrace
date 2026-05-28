require "rails_helper"

# Request-level coverage for the two PDF download routes. The sidecar + Spaces
# are stubbed here (no real browser/network); the end-to-end render is exercised
# in the system spec. This spec pins the auth boundary, the token gate, the
# redirect-to-signed-URL behavior, and the noindex header.
RSpec.describe "Report PDF downloads", type: :request do
  let(:job) { create(:job) }
  let!(:measurement) { create(:measurement, :complete, job: job) }
  let!(:report) { create(:report, job: job) }
  let(:signed_url) { "https://spaces.example.com/artifacts/#{job.id}/report.pdf?signed=1" }

  let(:username) { "demo" }
  let(:password) { "correct-horse" }

  around do |example|
    ENV["DEMO_USERNAME"] = username
    ENV["DEMO_PASSWORD_DIGEST"] = BCrypt::Password.create(password)
    example.run
  end

  before do
    fake = instance_double(ReportPdf, render: signed_url)
    allow(ReportPdf).to receive(:new).and_return(fake)
  end

  def log_in
    post login_path, params: { username: username, password: password }
  end

  describe "GET /r/:token.pdf (public share)" do
    it "redirects to the signed URL and sets X-Robots-Tag: noindex" do
      get "/r/#{report.share_token}.pdf"
      expect(response).to have_http_status(:see_other)
      expect(response.headers["Location"]).to eq(signed_url)
      expect(response.headers["X-Robots-Tag"]).to eq("noindex")
    end

    it "404s on a bad token (no login redirect)" do
      get "/r/not-a-real-token.pdf"
      expect(response).to have_http_status(:not_found)
      expect(response.headers["Location"]).to be_nil
    end

    it "is reachable without authentication" do
      get "/r/#{report.share_token}.pdf"
      expect(response).not_to redirect_to(login_path)
      expect(response).to have_http_status(:see_other)
    end
  end

  describe "GET /jobs/:id/report.pdf (authenticated)" do
    it "redirects an unauthenticated request to /login" do
      get "/jobs/#{job.id}/report.pdf"
      expect(response).to redirect_to(login_path)
    end

    it "redirects an authenticated request to the signed URL" do
      log_in
      get "/jobs/#{job.id}/report.pdf"
      expect(response).to have_http_status(:see_other)
      expect(response.headers["Location"]).to eq(signed_url)
    end
  end
end
