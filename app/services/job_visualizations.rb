# Builds the request-aware on-site-visualization array for the public JSON export
# (json_export 1.1.0, ADR-019). One entry per ProjectedOverlay for the job's
# captures, ordered most-pose-confident first (nil last), with SIGNED artifact
# URLs minted here (so the serializer stays request-agnostic, mirroring how
# pdf_url/share_url are injected). Returns [] when the job has no overlays.
#
# `photo_url` is null: the source capture photo lives under the `uploads/` prefix,
# which ArtifactUrlMinter (artifacts/-locked) cannot sign — the composite IS the
# exposed artifact. The schema permits null, so the field is emitted as null.
class JobVisualizations
  def self.for(job)
    new(job).to_a
  end

  def initialize(job)
    @job = job
  end

  def to_a
    # Emit EVERY overlay row, including low_pose_confidence/failed ones (which have
    # nil artifact refs -> null urls). The viewer surface shows low-confidence
    # captures as warnings; dropping them from the export would silently hide
    # failed captures, breaking parity. The schema permits null urls + null
    # photo_url, so an all-null entry (carrying only its pose_confidence) is valid.
    overlays.map do |overlay|
      {
        "photo_url" => nil,
        "composite_url" => signed(overlay.composite_ref),
        "overlay_svg_url" => signed(overlay.overlay_svg_ref),
        "pose_confidence" => overlay.pose_confidence
      }
    end
  end

  private

  def overlays
    return [] if @job.nil?
    return [] unless defined?(ProjectedOverlay) && defined?(CaptureSession)

    capture_ids = Capture.joins(:capture_session)
                         .where(capture_sessions: { job_id: @job.id })
                         .select(:id)
    ProjectedOverlay.where(capture_id: capture_ids)
                    .to_a
                    .sort_by { |o| -(o.pose_confidence || -Float::INFINITY) }
  rescue ActiveRecord::StatementInvalid
    []
  end

  def signed(ref)
    return nil if ref.blank?

    ArtifactUrlMinter.call(object_key: ref)
  rescue ArtifactUrlMinter::Error
    nil
  end
end
