# Projects the fused measurement's facets onto each captured iOS photo
# (ADR-019), producing the on-site overlay composites the viewer + PDF surface.
# Chained off FusionOrchestrator after a converged fusion commits the solved
# ARKit->UTM transform to the measurement's provenance.
#
# Mirrors FusionJob's discipline: projection is ADDITIVE and the job is already
# :ready, so this job NEVER calls advance_to!/fail_with!. A bounded retry covers
# a transient sidecar blip; a persistent failure leaves the canonical measurement
# (and whatever overlays already persisted) intact and the :ready status unchanged.
class ProjectionJob < ApplicationJob
  MAX_ATTEMPTS = 3

  queue_as :default

  retry_on StandardError, attempts: MAX_ATTEMPTS, wait: :polynomially_longer

  def perform(job_id)
    job = nil
    job = Job.find(job_id)
    ProjectionOrchestrator.call(job)
  rescue StandardError => e
    # The job status is NEVER touched — projection is additive and the job is
    # already :ready. Record a diagnostic on EVERY attempt (including the final,
    # exhausted one) so an operator always sees the failure reason on the Job row;
    # re-raise so Solid Queue applies the bounded retry / marks the execution
    # failed on exhaustion.
    if job
      job.update!(last_error: last_error_for(e))
    end
    raise
  end

  private

  def last_error_for(error)
    if executions >= MAX_ATTEMPTS
      "Projection failed after #{MAX_ATTEMPTS} attempts: #{error.class}"
    else
      "Projection crashed (attempt #{executions}): #{error.class}"
    end
  end
end
