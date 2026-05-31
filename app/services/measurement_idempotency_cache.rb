# Idempotency lookup for the measurement pipeline.
#
# A measurement generated within IDEMPOTENCY_WINDOW for the same Job is reused
# instead of re-running the pipeline — but ONLY when its stored input
# fingerprint still matches the job's current address+polygon_selection. A Job
# can be reused after an address/selection edit, and reusing a measurement built
# from the old inputs would serve a stale result.
#
# The fingerprint is a stable digest of the inputs that fully determine the
# pipeline output (address + polygon_selection). The orchestrator also persists
# this fingerprint on the new measurement row, so this object owns the canonical
# fingerprint computation and exposes it for that write.
class MeasurementIdempotencyCache
  # Idempotency window: a re-submission for the same address+polygon_selection
  # within this window reuses the cached measurement.
  IDEMPOTENCY_WINDOW = 1.hour

  def initialize(job, logger: Rails.logger)
    @job = job
    @logger = logger
  end

  # Return a still-valid cached Measurement for the job, or nil. A cache hit on a
  # job stuck mid-pipeline (a prior run created the measurement but crashed before
  # advancing to :ready) also advances the job to :ready so the status page
  # reflects the available measurement. A :ready job is left alone; a :failed job
  # is terminal and advance_to! would (correctly) refuse, so we only advance from
  # a non-terminal, non-ready status.
  def cached_measurement
    recent = @job.latest_measurement
    return nil if recent.nil?
    return nil if recent.generated_at.nil?
    return nil if recent.generated_at < IDEMPOTENCY_WINDOW.ago
    return nil unless recent.source_fingerprint == fingerprint

    @logger.info("[MeasurementIdempotencyCache] reusing measurement #{recent.id} " \
                 "(generated #{recent.generated_at.iso8601}) for job #{@job.id}")
    @job.advance_to!(:ready) if !@job.ready? && !@job.terminal?
    recent
  end

  # A stable digest of the inputs that fully determine the pipeline output. Any
  # change to the address or the selected building polygon yields a different
  # fingerprint, so a cached measurement built from prior inputs is not reused.
  #
  # Memoized — computed in both cached_measurement and the persistence write
  # within one run. Length-prefix each field so the join is unambiguous regardless
  # of field contents (an address can itself contain any separator char, including
  # a pipe), and use only printable ASCII (no control/NUL bytes in source).
  def fingerprint
    @fingerprint ||= begin
      address = @job.address.to_s
      selection = @job.polygon_selection.to_s
      Digest::SHA256.hexdigest("#{address.length}:#{address}|#{selection.length}:#{selection}")
    end
  end
end
