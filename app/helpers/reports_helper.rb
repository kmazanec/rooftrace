# View helpers for the report viewer's honest-uncertainty UX. The labels here
# MUST agree with the React island's TypeScript equivalents
# (app/javascript/viewer/utils/{sourceLabel,confidenceLabel}.ts) so the side
# panel and the map tooltips read the same.
module ReportsHelper
  # GeometrySource enum (lidar|imagery|fusion|capture|manual) -> the methodology
  # label shown next to every measurement number.
  def methodology_label(source)
    case source.to_s
    when "lidar"   then "from LiDAR"
    when "imagery" then "from satellite imagery"
    when "fusion"  then "from LiDAR + imagery"
    when "capture" then "from on-site capture"
    when "manual"  then "manually entered"
    else "source unknown"
    end
  end

  # Confidence (0..1) -> qualitative band matching report.css's
  # .report-confidence[data-level] thresholds.
  def confidence_level(confidence)
    c = confidence.to_f
    return "high" if c >= 0.8
    return "medium" if c >= 0.6

    "low"
  end

  # Below 0.6 a facet renders with the dashed-outline "uncertain reading" marker.
  def low_confidence?(confidence)
    confidence.to_f < 0.6
  end

  # Pitch ratio (rise per 12) -> "6:12 (26.6°)".
  def pitch_display(ratio)
    return "—" if ratio.nil?

    degrees = (Math.atan(ratio.to_f / 12.0) * 180.0 / Math::PI).round(1)
    "#{format_ratio(ratio)}:12 (#{degrees}°)"
  end

  def format_ratio(ratio)
    r = ratio.to_f
    (r % 1).zero? ? r.to_i.to_s : r.round(1).to_s
  end

  # Resolve a dedicated PDF/JSON download path for the current viewer context, or
  # nil when that download surface cannot be resolved (so the footer renders a
  # disabled "generating…/coming soon" affordance instead of a broken link).
  #
  # The PDF download (/jobs/:id/report.pdf, /r/:token.pdf) and the JSON export
  # (/api/v1/jobs/:id.json, /r/:token.json) are real routes. The viewer renders
  # in two contexts and each has its own pair of routes:
  #   - public share (@public): token-gated /r/:token.{pdf,json}
  #   - contractor (authenticated): /jobs/:id/report.pdf + /api/v1/jobs/:id.json
  # format: :pdf | :json.
  def report_download_path(format)
    if @public
      token = @report&.share_token
      return nil if token.blank?

      case format
      when :pdf  then public_report_pdf_path(token: token)
      when :json then public_report_export_path(token: token)
      end
    else
      return nil if @job.nil?

      case format
      when :pdf  then report_pdf_job_path(@job)
      when :json then api_v1_job_export_path(id: @job)
      end
    end
  end
end
