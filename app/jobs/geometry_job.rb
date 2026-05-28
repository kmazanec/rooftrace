# PLACEHOLDER — built by the F-11 agent to satisfy test stubs and enqueue calls.
# The real implementation is delivered by the F-10 agent (parallel workstream).
# The integrator MUST replace this file with the real GeometryJob from F-10;
# this stub exists only to make the test suite self-contained.
#
# Contract: GeometryJob.perform_later(job_id) enqueues a job that drives the
# status transitions on the Job record (via advance_to!/fail_with!).
class GeometryJob < ApplicationJob
  queue_as :default

  def perform(job_id)
    # No-op placeholder. The real implementation drives the geospatial pipeline.
    Rails.logger.info "[GeometryJob PLACEHOLDER] job_id=#{job_id} — no-op; replace with F-10 implementation."
  end
end
