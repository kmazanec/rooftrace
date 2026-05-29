# Drives the additive ICP-fusion step for a Job that already has a LiDAR-derived
# measurement (ADR-007: the iOS capture refines, never replaces, the canonical
# measurement; ADR-008: Rails owns orchestration, the sidecar owns the geometry).
#
# Load-bearing invariants:
#   * Fusion is ADDITIVE — on convergence it creates a NEW Measurement row whose
#     newer generated_at makes it win Job#latest_measurement. The prior
#     LiDAR-only measurement is left intact as the historical/fallback answer.
#   * The job is already :ready when a capture bundle arrives. This orchestrator
#     NEVER calls advance_to! or fail_with! — touching status would either raise
#     on the terminal guard or corrupt a finished job. All progress feedback is
#     the SEPARATE [job, :fusion_status] Turbo stream.
#   * ICP non-convergence or a sidecar error is non-fatal: it appends an
#     idempotent warning to the EXISTING measurement and leaves it canonical. No
#     new row, no status change.
class FusionOrchestrator
  # The fused-row source string. The sidecar returns GeometrySource.FUSION
  # ('fusion', a valid schema enum) on the embedded Measurement; Rails maps that
  # to this richer display string when persisting the row. measurements.source is
  # a plain varchar (no DB enum constraint), so the expanded value is fine.
  FUSED_SOURCE = "lidar+device+imagery".freeze

  # ICP convergence gate (matches the sidecar's own threshold): an RMSE at/above
  # this is treated as a failed alignment.
  ICP_RMSE_FAIL_THRESHOLD = 0.5

  def self.call(job, capture_session)
    new(job, capture_session).call
  end

  def self.append_failure_warning(job, message)
    measurement = job.latest_measurement
    return if measurement.nil?
    return if Array(measurement.warnings).include?(message)

    measurement.update!(warnings: Array(measurement.warnings) + [ message ])
  end

  def initialize(job, capture_session, sidecar: SidecarClient, logger: Rails.logger)
    @job = job
    @capture_session = capture_session
    @sidecar = sidecar
    @logger = logger
  end

  def call
    prior = @job.latest_measurement
    unless lidar_available?(prior)
      append_failure_warning("icp_skipped: lidar_unavailable")
      broadcast(state: :failed, icp_rmse_m: nil)
      return nil
    end

    broadcast(state: :started, icp_rmse_m: nil)

    response = @sidecar.fuse_capture(
      job_id: @job.id,
      capture_mesh_ref: @capture_session.world_mesh_ref,
      lidar: prior.lidar,
      timeout: SidecarClient::FUSE_CAPTURE_TIMEOUT_SECONDS
    )

    rmse = response["icp_rmse_m"]
    # A converged fused measurement MUST carry a finite RMSE — it's the gate's
    # only evidence the alignment is good. A nil/missing rmse alongside a present
    # measurement is a malformed/non-converged result; treat it as a failure
    # rather than letting `.to_f` coerce nil to 0.0 and slip past the threshold.
    rmse_missing = rmse.nil? && !response["measurement"].nil?
    if response["measurement"].nil? || rmse_missing || rmse.to_f >= ICP_RMSE_FAIL_THRESHOLD
      append_failure_warning("icp_alignment_failed: rmse=#{rmse}m")
      broadcast(state: :failed, icp_rmse_m: rmse)
      return nil
    end

    measurement = persist_fused_measurement(prior, response)
    broadcast(state: :complete, icp_rmse_m: rmse)
    # Chain the on-site photo-overlay projection (ADR-019): the fused measurement
    # now carries the solved ARKit->UTM transform in its provenance, so the
    # projection stage can place facets in each photo's frame. Enqueued (not run
    # inline) so the fusion response isn't held open by the projection compute;
    # ProjectionJob is idempotent + safe to re-trigger for an already-fused job.
    ProjectionJob.perform_later(@job.id)
    measurement
  rescue SidecarClient::Error => e
    # Sidecar 5xx / transport / timeout / schema drift: the original measurement
    # stands. Append an idempotent warning, surface :failed, and re-raise so the
    # job's bounded retry can re-attempt a transient blip.
    @logger.warn("[FusionOrchestrator] sidecar fusion failed for job #{@job.id}: #{e.class}")
    append_failure_warning("fusion_failed: sidecar_error")
    broadcast(state: :failed, icp_rmse_m: nil)
    raise
  end

  private

  def append_failure_warning(message)
    self.class.append_failure_warning(@job, message)
  end

  def lidar_available?(measurement)
    return false if measurement.nil?

    measurement.lidar.is_a?(Hash) && measurement.lidar["status"] == "LIDAR_AVAILABLE"
  end

  # Create the additive fused Measurement. NOT inside job.transaction: this is a
  # standalone additive insert, not a re-run of the pipeline's measurement+status
  # transaction. The Turbo broadcast happens in #call AFTER this returns, never
  # inside a transaction (an ActionCable publish must not be held open).
  def persist_fused_measurement(prior, response)
    fused = response["measurement"]
    @job.measurements.create!(
      footprint: fused["footprint"] || prior.footprint,
      roof_outline: fused["roof_outline"] || prior.roof_outline,
      lidar: prior.lidar,
      facets: Array(fused["facets"]),
      features: Array(fused["features"]),
      total_area_sq_ft: fused["total_area_sq_ft"],
      predominant_pitch_ratio: fused["predominant_pitch_ratio"],
      source: FUSED_SOURCE,
      confidence: fused_confidence(prior.confidence, response["icp_rmse_m"]),
      warnings: [],
      provenance: fused_provenance(prior, response),
      total_perimeter_ft: prior.total_perimeter_ft,
      geocode: prior.geocode,
      parcel_polygon: prior.parcel_polygon,
      # A fused measurement is a different artifact than the LiDAR-only one; it
      # must not inherit the prior's input fingerprint or the orchestrator's
      # idempotency cache could later serve it for a plain re-run. Leave it nil.
      source_fingerprint: nil,
      generated_at: Time.current
    )
  end

  # confidence = prior + 0.05 + clamp((0.5 - rmse) * 0.1, 0.0, 0.15), then
  # clamped to [prior, 1.0] so a fused row is never LESS confident than the
  # LiDAR-only measurement it refines. Rounded to 4 dp to match the pipeline.
  def fused_confidence(prior_confidence, icp_rmse_m)
    prior = prior_confidence.to_f
    bonus = [ [ (0.5 - icp_rmse_m.to_f) * 0.1, 0.15 ].min, 0.0 ].max
    (prior + 0.05 + bonus).clamp(prior, 1.0).round(4)
  end

  # Carry the prior provenance forward, annotated with the fusion inputs so a
  # report can state how the on-site capture refined the measurement. The solved
  # ARKit->UTM transform + its UTM EPSG (when the sidecar returned them on
  # convergence) are recorded under the Measurement::FUSION_* keys so a later
  # photo-projection stage reuses the solved transform instead of re-solving it.
  def fused_provenance(prior, response)
    base = prior.provenance.is_a?(Hash) ? prior.provenance.dup : {}
    base.merge(
      "fusion_icp_rmse_m" => response["icp_rmse_m"],
      "fusion_session_id" => @capture_session.id,
      "fusion_capture_mesh_ref" => @capture_session.world_mesh_ref
    ).tap do |prov|
      arkit_to_utm = response["arkit_to_utm"]
      utm_epsg = response["utm_epsg"]
      prov[Measurement::FUSION_ARKIT_TO_UTM_KEY] = arkit_to_utm unless arkit_to_utm.nil?
      prov[Measurement::FUSION_UTM_EPSG_KEY] = utm_epsg unless utm_epsg.nil?
    end
  end

  # Replace the per-job fusion-status partial on its own Turbo stream (distinct
  # from the [job, :status] pipeline stream). Called OUTSIDE any transaction.
  def broadcast(state:, icp_rmse_m:)
    Turbo::StreamsChannel.broadcast_replace_to(
      [ @job, :fusion_status ],
      target: ActionView::RecordIdentifier.dom_id(@job, :fusion_status),
      partial: "jobs/fusion_status",
      locals: { job: @job, state: state, icp_rmse_m: icp_rmse_m }
    )
  end
end
