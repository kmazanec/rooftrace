# Request-level tests for the job submission flow (F-11).
#
# Covers:
#   - Auth gate: unauthenticated requests → 302 to /login
#   - GET /jobs/new: form renders
#   - POST /jobs: creates a job, enqueues GeometryJob, redirects to status page
#   - GET /jobs/:id: status page renders for the job owner
#
# ActionCable broadcast-sequence assertions live in spec/models/job_broadcast_spec.rb.
# System-level flow (submit → status → ready) lives in spec/system/job_submission_spec.rb.

require "rails_helper"

RSpec.describe "Jobs", type: :request do
  let(:username) { "demo" }
  let(:password) { "correct-horse" }
  let(:digest)   { BCrypt::Password.create(password) }

  around do |example|
    ENV["DEMO_USERNAME"] = username
    ENV["DEMO_PASSWORD_DIGEST"] = digest
    example.run
  end

  # ---------------------------------------------------------------------------
  # Auth gate
  # ---------------------------------------------------------------------------

  describe "auth gate" do
    it "redirects unauthenticated GET /jobs/new to /login" do
      get new_job_path
      expect(response).to redirect_to(login_path)
    end

    it "redirects unauthenticated POST /jobs to /login" do
      post jobs_path, params: { job: { address: "123 Main St" } }
      expect(response).to redirect_to(login_path)
    end

    it "redirects unauthenticated GET /jobs/:id to /login" do
      job = create(:job)
      get job_path(job)
      expect(response).to redirect_to(login_path)
    end
  end

  # ---------------------------------------------------------------------------
  # Authenticated flows
  # ---------------------------------------------------------------------------

  describe "authenticated" do
    before do
      post login_path, params: { username: username, password: password }
    end

    describe "GET /jobs/new" do
      it "renders 200 with the address form" do
        get new_job_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("address")
      end

      it "includes inline guidance copy" do
        get new_job_path
        expect(response.body).to include("US residential address")
      end
    end

    describe "POST /jobs" do
      it "creates a job with the given address" do
        expect {
          post jobs_path, params: { job: { address: "742 Evergreen Terrace, Springfield, IL" } }
        }.to change(Job, :count).by(1)

        job = Job.last
        expect(job.address).to eq("742 Evergreen Terrace, Springfield, IL")
      end

      it "enqueues GeometryJob for the new job" do
        expect {
          post jobs_path, params: { job: { address: "742 Evergreen Terrace, Springfield, IL" } }
        }.to have_enqueued_job(GeometryJob)
      end

      it "turbo-redirects to the job status page (HTML redirect)" do
        post jobs_path, params: { job: { address: "742 Evergreen Terrace, Springfield, IL" } }
        job = Job.last
        expect(response).to redirect_to(job_path(job))
      end

      it "returns 422 when address is blank" do
        post jobs_path, params: { job: { address: "" } }
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    describe "GET /jobs/:id" do
      let(:job) { create(:job) }

      it "renders the status page with the address" do
        get job_path(job)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(job.address)
      end

      it "includes the per-stage status partial" do
        get job_path(job)
        expect(response.body).to include(ActionView::RecordIdentifier.dom_id(job, :status))
      end

      it "returns 404 for an unknown job id" do
        get job_path(id: SecureRandom.uuid)
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
