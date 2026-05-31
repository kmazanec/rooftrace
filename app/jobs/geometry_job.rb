# Runs the measurement pipeline for a Job on Solid Queue (ADR-008: Rails owns
# the jobs). Loads the Job and hands it to the MeasurementOrchestrator, which
# drives the per-stage sidecar calls, the parallel VLM detection, status
# broadcasts, and persistence of the unified Measurement.
#
# Retry policy: the orchestrator already converts every *expected* failure mode
# (no building footprint, schema/contract drift, stage timeout, sidecar error)
# into a terminal `job.fail_with!` and returns nil WITHOUT raising — those must
# NOT retry, since a re-run would deterministically hit the same wall (a geocode
# with no building stays a geocode with no building), and they never reach the
# rescue below.
#
# This job only guards against *unexpected* errors (a bug, an OOM, a brief
# sidecar blip): it must let Solid Queue actually retry them. The trap to avoid:
# marking the Job terminal (`fail_with!`) before re-raising defeats the retry —
# the re-run hits `return if job.terminal?` and no-ops, so a transient crash
# permanently fails after one real attempt. Instead we keep the Job in a
# non-terminal, retryable state (recording the error in `last_error`) on every
# attempt EXCEPT the last, and only call `fail_with!` once retries are exhausted
# (`executions >= MAX_ATTEMPTS`). The terminal-job no-op guard still protects
# against a stray duplicate run of an already-finished job — that path never
# enters this rescue.
class GeometryJob < ApplicationJob
  # Bounded retry for genuinely-transient unexpected errors. `executions` (the
  # ActiveJob attempt counter, 1-based on the first run) is keyed off this so the
  # final attempt — and only the final attempt — marks the Job terminally failed.
  MAX_ATTEMPTS = 3

  queue_as :default

  retry_on StandardError, attempts: MAX_ATTEMPTS, wait: :polynomially_longer

  def perform(job_id)
    job = nil
    job = Job.find(job_id)
    # A duplicate run for an already-terminal job (ready/failed) must be a no-op,
    # not a resurrection — don't re-run the pipeline over a finished job. An
    # unexpected-error retry does NOT hit this: an intermediate attempt leaves
    # the job non-terminal (see the rescue) precisely so the retry re-runs.
    return if job.terminal?

    MeasurementOrchestrator.call(job)
  rescue StandardError => e
    # Unexpected error — the orchestrator handles the expected ones itself.
    if job && !job.terminal?
      if executions >= MAX_ATTEMPTS
        # Retries exhausted: now record the failure terminally so the status
        # page reflects reality and no further re-run resurrects the job.
        job.fail_with!("Measurement pipeline crashed: #{e.class}")
      else
        # Intermediate attempt: record diagnostic detail WITHOUT going terminal,
        # so the retry can re-run the pipeline.
        job.update!(last_error: "Measurement pipeline crashed (attempt #{executions}): #{e.class}")
      end
    end
    raise
  end
end
