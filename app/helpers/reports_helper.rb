# View helpers for the report viewer's honest-uncertainty UX. The labels here
# MUST agree with the React island's TypeScript equivalents
# (app/javascript/viewer/utils/{sourceLabel,confidenceLabel}.ts) so the side
# panel and the map tooltips read the same.
#
# Pitch math is routed through PitchMath.degrees (app/services/pitch_math.rb) —
# single source for the atan formula. Feature labels are normalised by
# feature_label_display using `.humanize` (title-cased first word only, no
# ALL-CAPS abbreviation expansion) so the viewer side-panel and the PDF table
# agree on capitalisation.
module ReportsHelper
  # The display-level context the limitations partial reads. A plain Struct (not
  # OpenStruct) keeps the shape fixed and testable.
  LimitationsContext = Struct.new(:confidence_pct, :source, :has_lidar)

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
  # Degree conversion is delegated to PitchMath.degrees (single source of truth).
  def pitch_display(ratio)
    return "—" if ratio.nil?

    degrees = PitchMath.degrees(ratio)
    "#{format_ratio(ratio)}:12 (#{degrees}°)"
  end

  # Inline a brand SVG asset directly into the markup, for the PDF render path.
  # Grover/Chromium renders the report HTML as a bare string with NO base URL, so
  # a relative `/assets/...<img src>` can't be fetched (it shows broken alt text).
  # Inlining the (small) SVG markup makes the wordmark render with no network/host
  # dependency, in dev and prod alike. Returns "" if the asset is missing rather
  # than breaking the whole PDF render over a logo.
  def inline_brand_svg(filename, aria_label:, css_class: nil)
    path = Rails.root.join("app/assets/images/brand", filename)
    return "".html_safe unless File.exist?(path)

    svg = File.read(path)
    # Add only attributes the source <svg> doesn't already declare, so we never
    # emit duplicate role/aria-label. The asset is trusted + shape-stable, so a
    # regex on the opening tag is fine (no XML parser dependency).
    open_tag = svg[/<svg\b[^>]*>/] || "<svg>"
    attrs = +""
    attrs << %( role="img") unless open_tag.include?("role=")
    attrs << %( aria-label="#{ERB::Util.html_escape(aria_label)}") unless open_tag.include?("aria-label=")
    attrs << %( class="#{ERB::Util.html_escape(css_class)}") if css_class.present? && !open_tag.include?("class=")
    svg.sub(/<svg\b/, "<svg#{attrs}").html_safe
  end

  # Inline a stylesheet's contents into a <style> tag, for the PDF render path.
  # Same reason as inline_brand_svg: Grover renders with no base URL, so a
  # `<link href="/assets/report-<digest>.css">` can't be fetched and the PDF
  # renders UNSTYLED (Chromium defaults). report.css uses only system-font
  # fallbacks (no @font-face/url()/@import), so inlining its bytes fully styles
  # the document with zero external fetches. Returns "" if the file is missing.
  def inline_stylesheet(name)
    path = Rails.root.join("app/assets/stylesheets", "#{name}.css")
    return "".html_safe unless File.exist?(path)

    content_tag(:style, File.read(path).html_safe, media: "all")
  end

  # Raw feature key -> human-readable label.
  # Policy: `.humanize` — capitalises the first word only, converts underscores
  # to spaces, and leaves subsequent words lower-case (e.g. "skylight_vent" ->
  # "Skylight vent"). `.titleize` was deliberately NOT chosen because it
  # ALL-CAPS-expands abbreviations and title-cases every word, producing
  # inconsistent output for compound terms. One policy, one place.
  def feature_label_display(label)
    label.to_s.tr("-", "_").humanize
  end

  def format_ratio(ratio)
    r = ratio.to_f
    (r % 1).zero? ? r.to_i.to_s : r.round(1).to_s
  end

  # Derive the display-level context values for the limitations partial so the
  # domain decisions live in a unit-testable helper rather than in ERB scriptlets.
  # Returns a LimitationsContext with:
  #   :confidence_pct  Integer|nil   — rounded percentage (nil when confidence absent)
  #   :source          String        — provenance geometry_source if present, else
  #                                    measurement.source stringified
  #   :has_lidar       Boolean       — true when source implies LiDAR was used
  def report_limitations_context(measurement)
    confidence_pct = measurement.confidence.present? ? (measurement.confidence.to_f * 100).round : nil
    source = measurement.provenance&.dig("geometry_source") || measurement.source.to_s
    has_lidar = source.in?(%w[lidar fusion capture])
    LimitationsContext.new(confidence_pct, source, has_lidar)
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

  # The LiDAR point-cloud overlay endpoint for the current viewer context, or nil
  # when the measurement has no usable LiDAR (so the viewer renders the toggle in
  # an honest disabled "LiDAR not available" state rather than fetching nothing).
  # Public share -> token-gated /r/:token/lidar_points; contractor ->
  # /jobs/:id/report/lidar_points. ADR-013.
  def lidar_points_path_for_viewer(measurement)
    return nil unless measurement&.lidar_available?

    if @public
      token = @report&.share_token
      token.present? ? public_report_lidar_points_path(token: token) : nil
    else
      @job ? lidar_points_job_path(@job) : nil
    end
  end
end
