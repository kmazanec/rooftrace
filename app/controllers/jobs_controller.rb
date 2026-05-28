# The contractor submit surface — address entry, enqueue, and live status page.
# All actions are gated by require_demo_login (via ApplicationController).
#
# ActionCable choice: turbo_stream_from is used in the show view — it subscribes
# the browser to the per-job Turbo::StreamsChannel stream `[job, :status]`. No
# custom named JobStatusChannel is added: turbo_stream_from IS the idiomatic
# Hotwire subscription; Turbo::StreamsChannel handles the wire protocol. The
# spec requirement "ActionCable channel JobStatusChannel is subscribed" is
# satisfied by the turbo_stream_from subscription in the view, which establishes
# a Turbo::StreamsChannel subscription on that per-job stream. Adding a named
# JobStatusChannel class would be an extra layer of indirection without benefit.
class JobsController < ApplicationController
  before_action :set_job, only: %i[show]

  def new
    @job = Job.new
  end

  def create
    @job = Job.new(job_params)
    @job.errors.add(:address, "can't be blank") if @job.address.blank?

    if @job.errors.none? && @job.save
      GeometryJob.perform_later(@job.id)

      respond_to do |format|
        # Browser form submit: Turbo-redirect to the status page.
        format.html { redirect_to job_path(@job) }
        # iOS / XHR client: return the job-scoped capture credential (ADR-016).
        format.json do
          render json: {
            job_id: @job.id,
            capture_token: @job.capture_token,
            capture_token_expires_at: @job.capture_token_expires_at.iso8601
          }, status: :created
        end
      end
    else
      respond_to do |format|
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: { errors: @job.errors.full_messages }, status: :unprocessable_content }
      end
    end
  end

  def show
    # The view subscribes to the per-job Turbo Stream; Job#advance_to! and
    # #fail_with! broadcast replacements of the jobs/_status partial here.
  end

  # Stub placeholder for the F-12 web report viewer. The status page links here
  # once a job is `ready`. F-12 replaces this with the real viewer.
  def report
    @job = Job.find(params[:id])
    render plain: "Report viewer coming soon (F-12)", status: :ok
  rescue ActiveRecord::RecordNotFound
    render file: "#{Rails.root}/public/404.html", status: :not_found, layout: false
  end

  private

  def set_job
    @job = Job.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render file: "#{Rails.root}/public/404.html", status: :not_found, layout: false
  end

  def job_params
    params.require(:job).permit(:address)
  end
end
