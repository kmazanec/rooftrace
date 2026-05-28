# The contractor submit surface (gated by require_demo_login via
# ApplicationController). F-03 ships the minimal gated entry point plus a create
# action that mints the iOS capture token; the real address-entry + Solid Queue
# enqueue flow is F-11.
class JobsController < ApplicationController
  def new
    @job = Job.new
  end

  def create
    job = Job.create!(address: params.dig(:job, :address).to_s)

    respond_to do |format|
      # Browser form submit: send the contractor somewhere usable, not raw JSON.
      # The full submission/status flow is F-11; for now land back on the form.
      format.html { redirect_to new_job_path, notice: "Measurement started for #{job.address}." }
      # iOS / XHR client: return the job-scoped capture credential (ADR-016).
      format.json do
        render json: {
          job_id: job.id,
          capture_token: job.capture_token,
          capture_token_expires_at: job.capture_token_expires_at.iso8601
        }, status: :created
      end
    end
  end
end
