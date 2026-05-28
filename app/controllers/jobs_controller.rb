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

    # The iOS client needs the job-scoped capture credential to upload (ADR-016).
    render json: {
      job_id: job.id,
      capture_token: job.capture_token,
      capture_token_expires_at: job.capture_token_expires_at.iso8601
    }, status: :created
  end
end
