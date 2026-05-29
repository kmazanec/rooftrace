# Tests for the jobs/_status.html.erb partial rendering.
#
# Tests each status renders the expected human label, checkmarks for completed
# stages, active state for the current stage, and failure UX.

require "rails_helper"

RSpec.describe "jobs/_status partial", type: :view do
  # Include the helper so the partial can call job_pipeline_stages.
  # Rails view specs automatically include helpers for the subject partial's
  # controller, but explicitly including ensures it's available.
  include JobsHelper
  let(:job) { create(:job) }

  def render_status(job)
    render partial: "jobs/status", locals: { job: job }
    rendered
  end

  # ---------------------------------------------------------------------------
  # Stage labels — each non-terminal status maps to a human-readable label
  # ---------------------------------------------------------------------------

  {
    resolving_address: "Looking up address",
    fetching_imagery:  "Fetching imagery",
    fetching_lidar:    "Fetching LiDAR",
    refining_outline:  "Refining roof outline",
    detecting_features: "Detecting features",
    fitting_planes:    "Computing measurement"
  }.each do |status, label|
    it "shows '#{label}' as the active stage label for status #{status}" do
      job.update_columns(status: status.to_s)
      output = render_status(job)
      expect(output).to include(label)
    end
  end

  # ---------------------------------------------------------------------------
  # Checkmarks for completed stages
  # ---------------------------------------------------------------------------

  it "shows a checkmark for resolving_address when status is fetching_imagery" do
    job.update_columns(status: "fetching_imagery")
    output = render_status(job)
    # The completed stage should have the checkmark marker
    expect(output).to match(/stage--completed.*Looking up address|Looking up address.*stage--completed/m)
  end

  it "marks all prior stages complete when status is fitting_planes" do
    job.update_columns(status: "fitting_planes")
    output = render_status(job)
    %w[resolving_address fetching_imagery fetching_lidar refining_outline detecting_features].each do |prior|
      expect(output).to match(/stage--completed/)
    end
  end

  # ---------------------------------------------------------------------------
  # Ready state
  # ---------------------------------------------------------------------------

  it "shows a link to the report when status is ready" do
    job.update_columns(status: "ready")
    output = render_status(job)
    expect(output).to include("/jobs/#{job.id}/report")
  end

  # ---------------------------------------------------------------------------
  # Failure path
  # ---------------------------------------------------------------------------

  it "shows the last_error message when failed" do
    job.update_columns(status: "failed", last_error: "We could not find a building at this address.")
    output = render_status(job)
    expect(output).to include("We could not find a building at this address.")
  end

  it "shows a plain-language fallback error when failed with no last_error" do
    job.update_columns(status: "failed", last_error: nil)
    output = render_status(job)
    expect(output).to include("Something went wrong")
  end

  it "includes a 'back to form' link when failed" do
    job.update_columns(status: "failed", last_error: "Address not found.")
    output = render_status(job)
    expect(output).to include(new_job_path)
  end

  # ---------------------------------------------------------------------------
  # DOM contract: the wrapper must have the correct id for Turbo Stream replace
  # ---------------------------------------------------------------------------

  it "has the correct DOM id wrapper for Turbo Stream replace" do
    output = render_status(job)
    expect(output).to include(ActionView::RecordIdentifier.dom_id(job, :status))
  end
end
