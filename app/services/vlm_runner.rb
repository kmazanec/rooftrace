# Parallel, failure-isolated VLM feature-detection thread lifecycle.
#
# The VLM runs in a separate thread, concurrent with the geometric stages, and
# is failure-isolated: a VLM failure yields features:[] + a warning, the
# measurement still completes (ADR-006). This object isolates the thread/mutex
# choreography so it is independently testable:
#
#   * #start spawns the detector thread (against a just-rendered tile + the
#     building polygon prior).
#   * #join consumes the thread, returning the detected features (or [] on
#     failure/timeout, recording a vlm_failed warning).
#   * #cleanup kills/joins a still-in-flight thread if the pipeline exits early.
#
# It also owns the warnings buffer and its mutex: the detection thread's failure
# warnings and the main thread's pipeline warnings (lidar_missing, etc.) both
# write through #add_warning under the same mutex, so the buffer the orchestrator
# reads back (#warnings) is written safely from both threads.
class VlmRunner
  # How long the geometric chain will wait for the parallel VLM thread to finish
  # once geometry is done. Past this the VLM is abandoned (features:[]+warning)
  # rather than blocking the measurement.
  VLM_JOIN_TIMEOUT_SECONDS = 60

  # Grace period given to a timed-out VLM thread to unwind on its own before we
  # kill it. The detector's client carries its own open/read timeout, so a bare
  # immediate kill can sever the socket mid-request and leak it; we log, treat the
  # detection as failed (features:[]), and let the thread finish cleanly within
  # the grace before falling back to a kill.
  VLM_JOIN_GRACE_SECONDS = 5

  def initialize(detector_factory:, url_minter:, logger: Rails.logger)
    @detector_factory = detector_factory
    @url_minter = url_minter
    @logger = logger
    @warnings = []
    # The VLM thread and the main thread both append warnings; guard the buffer.
    @warnings_mutex = Mutex.new
    @thread = nil
  end

  # Append a warning under the mutex — the parallel VLM thread and the main thread
  # both write here.
  def add_warning(message)
    @warnings_mutex.synchronize { @warnings << message }
  end

  # The warnings accumulated so far (snapshot under the mutex).
  def warnings
    @warnings_mutex.synchronize { @warnings.dup }
  end

  # Spawn the VLM thread. The detector fetches the tile via a short-lived signed
  # URL we mint over our own Spaces object (SSRF-safe — see ImageryUrlMinter). A
  # failure inside the thread is captured, not raised, so it can't take down the
  # geometric chain; #join turns it into features:[] + a warning.
  def start(image_tile_ref:, roof_polygon:)
    @thread = Thread.new do
      image_tile_url = @url_minter.call(object_key: image_tile_ref)
      features = @detector_factory.build.detect(
        image_tile_url: image_tile_url,
        roof_polygon: roof_polygon
      )
      { features: Array(features) }
    rescue StandardError => e
      { error: "#{e.class}: #{e.message}" }
    end
  end

  # Consume the thread and return the detected features (or [] on failure/timeout,
  # recording a vlm_failed warning). Clears the held thread so #cleanup is a no-op
  # afterward (it only kills a thread still in flight because a geometric stage
  # raised before we got here).
  def join
    thread = @thread
    @thread = nil
    result = thread.join(VLM_JOIN_TIMEOUT_SECONDS)&.value
    if result.nil?
      @logger.warn("[MeasurementOrchestrator] VLM detection timed out after " \
                   "#{VLM_JOIN_TIMEOUT_SECONDS}s; abandoning (features:[])")
      thread.kill unless thread.join(VLM_JOIN_GRACE_SECONDS)
      add_warning("vlm_failed: detection timed out after #{VLM_JOIN_TIMEOUT_SECONDS}s")
      return []
    end
    if result[:error]
      add_warning("vlm_failed: #{result[:error]}")
      return []
    end
    result[:features]
  end

  # Kill/join the VLM thread if it is still alive when the pipeline exits for any
  # reason. Reuses #join's grace-then-kill discipline (a bare immediate kill can
  # sever the detector's socket mid-request). A nil held thread means #join already
  # consumed it (happy path) or the thread never started (early failure).
  def cleanup(job_id:)
    thread = @thread
    @thread = nil
    return if thread.nil?
    return unless thread.alive?

    @logger.warn("[MeasurementOrchestrator] cleaning up in-flight VLM thread " \
                 "after pipeline exited early (job #{job_id})")
    thread.kill unless thread.join(VLM_JOIN_GRACE_SECONDS)
  end
end
