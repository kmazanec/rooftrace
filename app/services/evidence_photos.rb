# Builds the ordered, capped list of on-site evidence photos that the
# `_evidence_photos` partial consumes: Array<{ image_url:, caption:, kind: }>.
#
# Used by ReportPdf (and only ReportPdf) to populate the evidence strip.
#
# Preference order:
#   1. Projected facet-overlay COMPOSITES, when the job has them — most
#      pose-confident first (ProjectedOverlay rows under
#      artifacts/<job_id>/projected/). This is what the AR-overlay workstream
#      fills in; until then there are no rows and the builder falls through.
#   2. Otherwise, normalized capture THUMBNAILS in capture order
#      (artifacts/<job_id>/evidence/, rendered by the sidecar on demand).
#
# Degrades to [] on any sidecar/minter failure — the evidence strip is omitted,
# never a 5xx (the partial renders nothing for an empty list).
class EvidencePhotos
  # How many on-site photos the report's evidence strip shows.
  CAP = 4

  def initialize(job)
    @job = job
  end

  # Builds the capped evidence list.
  #
  # @return [Array<Hash>]  Array<{ image_url:, caption:, kind: }>
  def build
    composites = composite_evidence_photos
    return composites.first(CAP) unless composites.empty?

    thumbnail_evidence_photos.first(CAP)
  rescue SidecarClient::Error, ArtifactUrlMinter::Error => e
    Rails.logger.warn("[EvidencePhotos] evidence photos unavailable, omitting section: #{e.class}")
    []
  end

  private

  # Projected composites from ProjectedOverlay rows, ordered most-pose-confident
  # first (a nil pose_confidence sorts last). Returns [] when the job has none.
  def composite_evidence_photos
    overlays = projected_overlays
    return [] if overlays.empty?

    ProjectedOverlay.sorted_by_pose_confidence(overlays)
      .filter_map do |overlay|
        ref = overlay.composite_ref
        next if ref.blank?

        {
          image_url: ArtifactUrlMinter.call(object_key: ref),
          caption: overlay.capture&.prompt_label.presence || "On-site visualization",
          kind: "composite"
        }
      end
  end

  # The ProjectedOverlay rows for this job's captures, if the capture surface and
  # the AR-overlay workstream exist yet. Returns [] when neither model nor rows
  # are present, so the builder degrades cleanly during incremental rollout.
  def projected_overlays
    return [] unless defined?(ProjectedOverlay) && defined?(CaptureSession)

    ProjectedOverlay.for_job(@job).includes(:capture).to_a
  rescue ActiveRecord::StatementInvalid
    []
  end

  # Normalized capture thumbnails in capture order, rendered by the sidecar on
  # demand. Returns [] when the job has no captures.
  def thumbnail_evidence_photos
    photos = capture_photo_specs
    return [] if photos.empty?

    response = SidecarClient.new.render_evidence_thumbnails(job_id: @job.id, photos: photos)
    Array(response["thumbnails"]).map do |thumb|
      {
        image_url: ArtifactUrlMinter.call(object_key: thumb["thumbnail_ref"]),
        caption: caption_for_sequence(photos, thumb["sequence_index"]),
        kind: "thumbnail"
      }
    end
  end

  # The { photo_ref:, sequence_index:, caption: } specs for this job's captures
  # (sequence_index ASC), or [] when the capture surface isn't present.
  def capture_photo_specs
    return [] unless defined?(CaptureSession)

    Capture.for_job(@job).with_photo.map do |capture|
      {
        "photo_ref" => capture.photo_ref,
        "sequence_index" => capture.sequence_index,
        "caption" => capture.prompt_label
      }
    end
  rescue ActiveRecord::StatementInvalid
    []
  end

  def caption_for_sequence(specs, sequence_index)
    spec = specs.find { |s| s["sequence_index"] == sequence_index }
    spec && spec["caption"].presence
  end
end
