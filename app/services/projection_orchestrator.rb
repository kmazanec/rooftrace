# Projects the fused measurement's facets onto each captured iOS photo, producing
# one ProjectedOverlay per Capture (ADR-019: AR-as-output — the server projects,
# the user sees). Chained off FusionOrchestrator after a converged fusion commits
# the solved ARKit->UTM transform to Measurement.provenance.
#
# Load-bearing invariants (mirror FusionOrchestrator):
#   * Projection is ADDITIVE and the job is already :ready — this orchestrator
#     NEVER calls advance_to!/fail_with!. It only writes ProjectedOverlay rows.
#   * Rails is the SINGLE authority on pose_confidence (ProjectionPoseConfidence):
#     below the threshold, NO sidecar call is made; a low_pose_confidence overlay
#     is persisted so the viewer/PDF warn rather than draw a misregistered overlay.
#   * Idempotent on existing overlays: a re-run updates a capture's existing
#     overlay rather than creating a duplicate (the capture_id unique index also
#     guards this at the DB).
#   * Requires the solved transform: a measurement predating the fusion-transform
#     provenance field has no way to place facets in the photo frame, so
#     projection is skipped entirely (no overlays).
class ProjectionOrchestrator
  def self.call(job, sidecar: SidecarClient, logger: Rails.logger)
    new(job, sidecar: sidecar, logger: logger).call
  end

  def initialize(job, sidecar: SidecarClient, logger: Rails.logger)
    @job = job
    @sidecar = sidecar
    @logger = logger
  end

  def call
    measurement = @job.latest_measurement
    return if measurement.nil?

    arkit_to_utm = measurement.fused_arkit_to_utm
    utm_epsg = measurement.fused_utm_epsg
    # No solved transform -> cannot place WGS84 facets in the ARKit-local photo
    # frame. Skip projection entirely (a measurement predating the field).
    if arkit_to_utm.nil? || utm_epsg.nil?
      @logger.info("[ProjectionOrchestrator] job #{@job.id}: no solved transform, skipping projection")
      return
    end

    icp_rmse_m = measurement.provenance.is_a?(Hash) ? measurement.provenance["fusion_icp_rmse_m"] : nil
    facets = Array(measurement.facets)

    # Projection is ADDITIVE per photo (mirror FusionOrchestrator: NEVER call
    # advance_to!/fail_with!). One bad photo must never starve the others, so each
    # capture is isolated in its own rescue: a sidecar failure degrades THAT photo
    # to a failed (low_pose_confidence) overlay — so the viewer/PDF surface a
    # warning instead of a silent gap — and the loop continues.
    #
    # Transient-vs-permanent retry decision: we record whether every failure was
    # transient (TimeoutError) and whether ANY capture succeeded. We re-raise to
    # let ProjectionJob's bounded retry run again ONLY when all captures failed
    # transiently — a re-run could turn those blips into real overlays. We do NOT
    # re-raise when a permanent failure occurred (a 422 unreadable photo won't fix
    # on retry — the failed overlay is the honest terminal state) or when any
    # capture already succeeded (retry must not re-run/clobber the good set; the
    # failed photos are already surfaced as warnings).
    any_success = false
    any_permanent_failure = false
    transient_failures = 0

    captures_for(@job).each do |capture|
      project_one(capture, facets: facets, arkit_to_utm: arkit_to_utm,
                  utm_epsg: utm_epsg, icp_rmse_m: icp_rmse_m)
      any_success = true
    rescue SidecarClient::Error => e
      transient = e.is_a?(SidecarClient::TimeoutError)
      transient ? (transient_failures += 1) : (any_permanent_failure = true)
      @logger.warn(
        "[ProjectionOrchestrator] job #{@job.id} capture #{capture.id}: " \
        "project_photo failed (#{e.class}#{transient ? ', transient' : ', permanent'}); " \
        "persisting failed overlay and continuing"
      )
      persist_low_confidence_overlay(capture, nil)
    end

    broadcast(state: :complete)

    if transient_failures.positive? && !any_permanent_failure && !any_success
      raise SidecarClient::Error,
            "projection: all #{transient_failures} capture(s) failed transiently; retrying"
    end
  end

  private

  # Captures with a photo, in capture order. A capture without a photo_ref has
  # nothing to project onto.
  def captures_for(job)
    Capture.joins(:capture_session)
           .where(capture_sessions: { job_id: job.id })
           .where.not(photo_ref: nil)
           .order(:sequence_index)
  end

  def project_one(capture, facets:, arkit_to_utm:, utm_epsg:, icp_rmse_m:)
    confidence = ProjectionPoseConfidence.score(
      icp_rmse_m: icp_rmse_m, extrinsics: capture.camera_extrinsics
    )

    unless ProjectionPoseConfidence.acceptable?(confidence)
      persist_low_confidence_overlay(capture, confidence)
      return
    end

    response = @sidecar.project_photo(
      job_id: @job.id,
      photo_ref: capture.photo_ref,
      camera_pose: { "intrinsics" => capture.camera_intrinsics, "extrinsics" => capture.camera_extrinsics },
      facets: facets,
      world_mesh_ref: capture.capture_session.world_mesh_ref,
      features: Array(@job.latest_measurement&.features),
      arkit_to_utm: arkit_to_utm,
      utm_epsg: utm_epsg,
      pose_confidence: confidence,
      timeout: SidecarClient::PROJECT_PHOTO_TIMEOUT_SECONDS
    )

    persist_overlay(capture, response, confidence)
  end

  # The sidecar may only NARROW pose_confidence; take the min of Rails' score and
  # whatever the sidecar returned (never raise it above Rails' authority).
  def effective_confidence(rails_score, sidecar_value)
    return rails_score if sidecar_value.nil?

    [ rails_score, sidecar_value.to_f ].min
  end

  def persist_overlay(capture, response, rails_confidence)
    confidence = effective_confidence(rails_confidence, response["pose_confidence"])

    # The sidecar may have NARROWED the confidence below the threshold (e.g. it
    # detected a degenerate projection). Re-check the gate against the effective
    # value: a narrowed-below-threshold overlay must NOT be stored as drawable, or
    # we'd surface exactly the misregistered overlay the gate exists to suppress.
    unless ProjectionPoseConfidence.acceptable?(confidence)
      persist_low_confidence_overlay(capture, confidence)
      return
    end

    overlay = ProjectedOverlay.find_or_initialize_by(capture_id: capture.id)
    overlay.update!(
      composite_ref: response["composite_ref"] || response["overlay_ref"],
      overlay_svg_ref: response["overlay_svg_ref"],
      pose_confidence: confidence,
      low_pose_confidence: false,
      occluded_facet_ids: Array(response["occluded_facet_ids"])
    )
  end

  def persist_low_confidence_overlay(capture, confidence)
    overlay = ProjectedOverlay.find_or_initialize_by(capture_id: capture.id)
    overlay.update!(
      composite_ref: nil,
      overlay_svg_ref: nil,
      pose_confidence: confidence,
      low_pose_confidence: true,
      occluded_facet_ids: []
    )
  end

  def broadcast(state:)
    Turbo::StreamsChannel.broadcast_replace_to(
      [ @job, :projection_status ],
      target: ActionView::RecordIdentifier.dom_id(@job, :projection_status),
      partial: "jobs/projection_status",
      locals: { job: @job, state: state }
    )
  rescue StandardError => e
    # A broadcast failure must never abort the (already-persisted) projection.
    @logger.warn("[ProjectionOrchestrator] projection_status broadcast failed: #{e.class}")
  end
end
