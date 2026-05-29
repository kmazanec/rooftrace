# Runs the additive ICP-fusion step for a Job whose iOS capture bundle has been
# ingested (ADR-007). Enqueued by the capture-sessions ingest controller once the
# bundle's blobs are uploaded and the CaptureSession row is committed.
#
# Mirrors GeometryJob's retry discipline for *unexpected* / transient failures
# (a brief sidecar blip, an OOM): a bounded retry via Solid Queue. But fusion is
# ADDITIVE and the job is already :ready — so unlike GeometryJob, this job NEVER
# calls advance_to! or fail_with! under any circumstance. A persistent failure
# leaves the canonical LiDAR-only measurement intact and records a warning on it;
# the job's :ready status never changes.
#
# Note on retry coverage: only failures the orchestrator RE-RAISES retry here.
# The orchestrator handles the EXPECTED outcomes itself without raising — ICP
# non-convergence and the lidar-unavailable skip append a warning and return nil
# (a re-run would deterministically hit the same wall). It re-raises only a
# sidecar transport/5xx/timeout/schema error, which IS worth a bounded retry.
class FusionJob < ApplicationJob
  MAX_ATTEMPTS = 3

  queue_as :default

  retry_on StandardError, attempts: MAX_ATTEMPTS, wait: :polynomially_longer

  def perform(job_id, capture_session_id)
    job = Job.find(job_id)
    capture_session = CaptureSession.find(capture_session_id)

    # Idempotency: a duplicate delivery for an already-fused job is a no-op. The
    # newest measurement already being the fused one means this work is done.
    return if job.latest_measurement&.source == FusionOrchestrator::FUSED_SOURCE

    FusionOrchestrator.call(job, capture_session)
  rescue StandardError => e
    # The job status is NEVER touched (no fail_with!) — fusion is additive and
    # the job is already :ready. On the final attempt, record an idempotent
    # warning on the existing measurement so the failure is visible, then re-raise
    # to let Solid Queue mark the job execution failed.
    if defined?(job) && job
      if executions >= MAX_ATTEMPTS
        FusionOrchestrator.append_failure_warning(job, "fusion_job_exhausted")
      else
        job.update!(last_error: "Fusion crashed (attempt #{executions}): #{e.class}")
      end
    end
    raise
  end
end
