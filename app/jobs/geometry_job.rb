# Runs the measurement pipeline for a Job on Solid Queue (ADR-008: Rails owns
# the jobs). Loads the Job and hands it to the MeasurementOrchestrator, which
# drives the per-stage sidecar calls, the parallel VLM detection, status
# broadcasts, and persistence of the unified Measurement.
#
# Retry policy: the orchestrator already converts every *expected* failure mode
# (no building footprint, schema/contract drift, stage timeout, sidecar error)
# into a terminal `job.fail_with!` and returns nil — those must NOT retry, since
# a re-run would deterministically hit the same wall (a geocode with no building
# stays a geocode with no building). So this job only guards against *unexpected*
# errors (a bug, an OOM, a deserialization issue): it records them on the job and
# re-raises so Solid Queue's bounded retry/dead-set can take over for the
# genuinely-transient case, rather than silently swallowing a programming error.
class GeometryJob < ApplicationJob
  queue_as :default

  def perform(job_id)
    job = Job.find(job_id)
    MeasurementOrchestrator.call(job)
  rescue StandardError => e
    # Unexpected error — the orchestrator handles the expected ones itself.
    # Mark the job failed (best effort) so the status page reflects reality,
    # then re-raise for the queue's retry/dead-set handling.
    if defined?(job) && job
      job.fail_with!("Measurement pipeline crashed: #{e.class}") unless job.terminal?
    end
    raise
  end
end
