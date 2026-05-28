require "rails_helper"

# Request-level coverage for the report viewer surfaces (ADR-013, ADR-016):
#   - contractor GET /jobs/:id/report (login-gated, lazy Report creation)
#   - public GET /r/:token (no auth, noindex, 404 on bad token, no leak)
#   - not-ready states (nil job / no measurement) render, never 500
#   - the serialized measurement payload is baked into the viewer mount element
RSpec.describe "Report viewer", type: :request do
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

  describe "contractor GET /jobs/:id/report" do
    let(:job) { create(:job, address: "123 Main St") }
    let!(:measurement) { create(:measurement, :with_geometry, job: job) }

    before { login! }

    it "renders the viewer with the measurement payload baked into the mount element" do
      get report_job_path(job)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-controller="viewer"')
      expect(response.body).to include("data-viewer-measurement-value")
      expect(response.body).to include("1,684") # total area, formatted
    end

    it "lazily creates a Report so the contractor can share the link" do
      expect { get report_job_path(job) }.to change { job.reports.count }.from(0).to(1)
    end

    it "is idempotent — a second visit does not create a duplicate Report" do
      get report_job_path(job)
      expect { get report_job_path(job) }.not_to(change { job.reports.count })
    end

    it "shows the contractor-only Generate share link control" do
      get report_job_path(job)
      expect(response.body).to include("Share link")
    end

    context "when the job has no measurement yet" do
      let(:job) { create(:job, address: "Pending Ave") }
      let!(:measurement) { nil }

      it "renders a not-ready state (never a 500)" do
        get report_job_path(job)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("not ready")
      end
    end
  end

  describe "public GET /r/:token" do
    let(:job) { create(:job, address: "123 Main St") }
    let!(:measurement) { create(:measurement, :with_geometry, job: job) }
    let(:report) { create(:report, job: job) }

    it "renders without login and sets X-Robots-Tag: noindex" do
      get public_report_path(token: report.share_token)
      expect(response).to have_http_status(:ok)
      expect(response.headers["X-Robots-Tag"]).to eq("noindex")
      expect(response).not_to redirect_to(login_path)
    end

    it "bakes the same measurement payload into the mount element" do
      get public_report_path(token: report.share_token)
      expect(response.body).to include('data-controller="viewer"')
      expect(response.body).to include("data-viewer-measurement-value")
    end

    it "does NOT show the Generate share link control" do
      get public_report_path(token: report.share_token)
      expect(response.body).not_to include("Generate share link")
    end

    it "returns 404 (not a redirect) for an unknown token" do
      get public_report_path(token: "Z" * 32)
      expect(response).to have_http_status(:not_found)
      expect(response).not_to redirect_to(login_path)
    end

    context "when the report's job has no measurement" do
      let!(:measurement) { nil }

      it "renders a not-ready state (never a 500)" do
        get public_report_path(token: report.share_token)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("not ready")
      end
    end

    context "when the report has a nil job" do
      let(:report) { create(:report, job: nil) }

      it "renders a not-ready state (never a 500)" do
        get public_report_path(token: report.share_token)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("not ready")
      end
    end
  end
end
