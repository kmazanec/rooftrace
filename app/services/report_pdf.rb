require "grover"
require "aws-sdk-s3"

# Composes the downloadable / shareable roof-measurement PDF (ADR-014, as
# amended to a single top-down map image_ref — oblique/3D deferred).
#
# Flow:
#   1. Resolve the job's latest measurement (raise if none).
#   2. Idempotency: if a report.pdf already exists in Spaces and is <30 min old,
#      return its signed URL without re-rendering.
#   3. Ask the sidecar to render a top-down map PNG (bbox from facet vertices).
#      On sidecar failure, degrade to the Mapbox Static fallback (a warning is
#      surfaced in the PDF footer; never an exception).
#   4. Mint a signed artifacts/ URL for the map PNG and embed it in the
#      print-layout ERB; run Grover (Puppeteer) to PDF bytes.
#   5. Upload the PDF to artifacts/<job_id>/report.pdf and return its signed URL.
#
# A Grover/Puppeteer failure is intentionally NOT rescued: it bubbles to the
# controller as a 5xx so the user can retry (ADR-014 failure mode).
class ReportPdf
  class Error < StandardError; end

  # Render at ~1600x1200 @ a print-friendly aspect. The sidecar renders at this
  # pixel size; the print CSS scales it into the page.
  MAP_WIDTH_PX = 1600
  MAP_HEIGHT_PX = 1200

  # A report.pdf younger than this is reused; older is re-rendered (the spec's
  # 30-minute idempotency window, enforced by probing the Spaces object's age so
  # no DB column is needed).
  CACHE_WINDOW = 30.minutes

  # Object-metadata flag marking a cached PDF as a degraded render (the map
  # renderer was unavailable and the static-map fallback / no-diagram path
  # engaged). A degraded cache entry is treated as a miss so a recovered renderer
  # re-renders a clean PDF on the next request rather than serving the degraded
  # one for the whole CACHE_WINDOW.
  DEGRADED_METADATA_KEY = "degraded".freeze

  def initialize(job, store: nil)
    @job = job
    @store = store || ArtifactStore.new
  end

  # @return [String] a signed https URL to the report PDF in Spaces.
  def render
    # An orphaned share (a Report whose job was destroyed -> job_id nullified)
    # has no job to render. Raise the rescued Error rather than NoMethodError on
    # nil so a public, unauthenticated caller never sees an unhandled 5xx.
    raise Error, "report has no job to render" if @job.nil?

    measurement = @job.latest_measurement
    raise Error, "job #{@job.id} has no measurement to render" if measurement.nil?

    cached = fresh_cached_pdf_url(measurement)
    return cached if cached

    bbox = bbox_from_facets(measurement)
    map_image_url, fallback_warning = map_image_url_for(measurement, bbox)
    evidence_photos = evidence_photos_for(measurement)

    html = render_html(measurement, map_image_url:, fallback_warning:, evidence_photos:)
    pdf_bytes = Grover.new(html, **grover_options).to_pdf

    # A degraded render (sidecar/static-map fallback engaged) must NOT poison the
    # idempotency window: caching it would serve a degraded PDF for the next
    # CACHE_WINDOW even after the renderer recovers. Tag the object so
    # fresh_cached_pdf_url treats a degraded cache entry as a miss and re-renders
    # on the next request.
    metadata = fallback_warning.present? ? { DEGRADED_METADATA_KEY => "1" } : {}
    @store.put(key: pdf_key, body: pdf_bytes, content_type: "application/pdf", metadata: metadata)

    ArtifactUrlMinter.call(object_key: pdf_key)
  end

  private

  def pdf_key
    "artifacts/#{@job.id}/report.pdf"
  end

  # A cached report.pdf is reusable only when ALL of these hold:
  #   - it exists and we know its age,
  #   - it is younger than CACHE_WINDOW (the time-based idempotency window),
  #   - it is NOT a degraded render (so a recovered renderer re-renders cleanly),
  #   - the measurement has not changed since the PDF was rendered (data changes
  #     trigger a re-render — a re-run orchestrator produces a newer Measurement
  #     row whose updated_at/generated_at is newer than the cached object).
  def fresh_cached_pdf_url(measurement)
    head = @store.head(pdf_key)
    return nil if head.nil?

    last_modified = head[:last_modified]
    return nil if last_modified.nil?
    return nil if last_modified < CACHE_WINDOW.ago
    return nil if degraded?(head)
    return nil if measurement_newer_than?(measurement, last_modified)

    ArtifactUrlMinter.call(object_key: pdf_key)
  end

  def degraded?(head)
    metadata = head[:metadata] || {}
    metadata[DEGRADED_METADATA_KEY].present?
  end

  # True when the measurement was created/updated after the cached PDF was
  # rendered, so the PDF no longer reflects current data.
  def measurement_newer_than?(measurement, last_modified)
    stamp = measurement.updated_at || measurement.generated_at
    return false if stamp.nil?

    stamp > last_modified
  end

  # Returns [signed_map_url, fallback_warning_message_or_nil]. The sidecar render
  # is the primary path; on any SidecarClient error we degrade to a Mapbox Static
  # image uploaded under artifacts/ and flag a warning for the footer.
  def map_image_url_for(measurement, bbox)
    response = SidecarClient.render_images(
      job_id: @job.id, bbox: bbox, width_px: MAP_WIDTH_PX, height_px: MAP_HEIGHT_PX
    )
    # The RenderImageResponse schema constrains image_ref to a string but NOT to
    # the artifacts/ prefix, so a sidecar bug could return a cache/ key or blank;
    # ArtifactUrlMinter raises on that. Treat any minter failure here the same as
    # a sidecar failure and degrade to the static-map fallback rather than 5xx.
    [ ArtifactUrlMinter.call(object_key: response.fetch("image_ref")), nil ]
  rescue SidecarClient::Error, ArtifactUrlMinter::Error => e
    Rails.logger.warn("[ReportPdf] sidecar render-images failed, using Mapbox Static fallback: #{e.class}")
    fallback_map_url(bbox)
  end

  def fallback_map_url(bbox)
    png = MapboxStaticFallback.call(bbox: bbox, width_px: MAP_WIDTH_PX, height_px: MAP_HEIGHT_PX)
    key = "artifacts/#{@job.id}/images/map-fallback.png"
    @store.put(key: key, body: png, content_type: "image/png")
    warning = "Roof diagram rendered from a static map image (degraded view): the " \
              "interactive map renderer was unavailable when this report was generated."
    [ ArtifactUrlMinter.call(object_key: key), warning ]
  # Beyond MapboxStaticFallback::Error, the Spaces put (ArtifactStore::Error /
  # Aws::S3::Errors) or the artifacts/ URL mint (ArtifactUrlMinter::Error) can
  # fail when Spaces is unavailable during the fallback upload. None of these
  # should abort the whole PDF: degrade to a no-diagram report with a warning.
  rescue MapboxStaticFallback::Error, ArtifactStore::Error, ArtifactUrlMinter::Error, Aws::S3::Errors::ServiceError => e
    Rails.logger.warn("[ReportPdf] Mapbox Static fallback failed: #{e.class}")
    warning = "Roof diagram unavailable: both the map renderer and the static-map " \
              "fallback were unavailable when this report was generated."
    [ nil, warning ]
  end

  # WGS84 [min_lon, min_lat, max_lon, max_lat] enclosing every facet vertex,
  # padded slightly so the roof is not flush against the image edge. Raises a
  # clear error if no facet has usable vertices.
  def bbox_from_facets(measurement)
    points = Array(measurement.facets).flat_map { |f| Array(f["vertices"]) }
                                      .select { |v| v.is_a?(Array) && v.length >= 2 }
    raise Error, "measurement has no facet vertices to compute a map bbox" if points.empty?

    lons = points.map { |v| v[0].to_f }
    lats = points.map { |v| v[1].to_f }
    pad_lon = [ (lons.max - lons.min) * 0.1, 0.00005 ].max
    pad_lat = [ (lats.max - lats.min) * 0.1, 0.00005 ].max
    [ lons.min - pad_lon, lats.min - pad_lat, lons.max + pad_lon, lats.max + pad_lat ]
  end

  def render_html(measurement, map_image_url:, fallback_warning:, evidence_photos:)
    # Latest completed capture session for this job (drives the site-visit and
    # methodology claim sections). Most-recently-ended first.
    capture_session = latest_capture_session
    methodology_sentences = ReportMethodology.call(measurement)
    visit_verification = visit_verification_for(capture_session, measurement)

    ApplicationController.render(
      template: "reports/show",
      formats: [ :pdf ],
      handlers: [ :erb ],
      layout: "report_print",
      assigns: {
        job: @job,
        measurement: measurement,
        map_image_url: map_image_url,
        fallback_warning: fallback_warning,
        evidence_photos: evidence_photos,
        capture_session: capture_session,
        methodology_sentences: methodology_sentences,
        visit_verification: visit_verification
      }
    )
  end

  # The job's most-recently-completed capture session, or nil. Returns nil when
  # the capture surface isn't present yet so the claim sections degrade cleanly.
  def latest_capture_session
    return nil unless defined?(CaptureSession)

    @job.capture_sessions.where.not(ended_at: nil).order(ended_at: :desc).first
  rescue ActiveRecord::StatementInvalid
    nil
  end

  # Builds the site-visit verification summary for the claim PDF (ADR-018), or
  # nil when there is no completed capture session.
  #
  # HONESTY: the "GPS-verified within N m of the geocoded address" claim is an
  # assertion in an insurance document, so it is made ONLY when a capture's
  # recorded GPS fix actually falls within CLAIM_PDF_VISIT_RADIUS_M (default 12 m)
  # of the geocoded address coordinates. Missing GPS or a too-distant nearest fix
  # yields gps_verified: false, and the partial softens the wording rather than
  # asserting an unverified fact.
  #
  # @return [Hash, nil]
  #   { photo_count:, visit_time:, radius_m:, gps_verified:, distance_m: }
  def visit_verification_for(capture_session, measurement)
    return nil if capture_session.nil?

    ended_at = capture_session.ended_at || capture_session.started_at || Time.current
    distance_m = nearest_capture_distance_m(capture_session, measurement)

    {
      photo_count: capture_session.captures.count,
      visit_time: ended_at.strftime("%Y-%m-%d %H:%M %Z"),
      radius_m: visit_radius_m,
      gps_verified: distance_m.present? && distance_m <= visit_radius_m,
      distance_m: distance_m&.round(1)
    }
  end

  # The configured "within N m of the geocoded address" radius (meters).
  def visit_radius_m
    (ENV["CLAIM_PDF_VISIT_RADIUS_M"].presence || "12").to_i
  end

  # Smallest great-circle distance (meters) between any capture's recorded GPS
  # fix and the measurement's geocoded address. Returns nil when no capture has
  # usable GPS or the address has no coordinates (so no false claim is made).
  def nearest_capture_distance_m(capture_session, measurement)
    geocode = measurement.geocode || {}
    addr_lat = geocode["lat"]
    addr_lon = geocode["lon"]
    return nil if addr_lat.blank? || addr_lon.blank?

    distances = capture_session.captures.filter_map do |capture|
      gps = capture.gps
      next unless gps.is_a?(Hash)

      lat = gps["latitude"]
      lon = gps["longitude"]
      next if lat.blank? || lon.blank?

      haversine_m(addr_lat.to_f, addr_lon.to_f, lat.to_f, lon.to_f)
    end
    distances.min
  end

  # Earth radius (meters) for the great-circle distance below.
  EARTH_RADIUS_M = 6_371_000.0

  # Great-circle distance in meters between two WGS84 lat/lon points.
  def haversine_m(lat1, lon1, lat2, lon2)
    rad = Math::PI / 180.0
    dlat = (lat2 - lat1) * rad
    dlon = (lon2 - lon1) * rad
    a = (Math.sin(dlat / 2)**2) +
        (Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * (Math.sin(dlon / 2)**2))
    EARTH_RADIUS_M * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
  end

  # How many on-site photos the report's evidence strip shows.
  EVIDENCE_PHOTO_CAP = 4

  # Builds the ordered, capped list the kind-agnostic `_evidence_photos` partial
  # consumes: Array<{ image_url:, caption:, kind: }>.
  #
  # Preference order (the seam between the two report stretch features):
  #   1. Projected facet-overlay COMPOSITES, when the job has them — most
  #      pose-confident first (ProjectedOverlay rows under
  #      artifacts/<job_id>/projected/). This is what the AR-overlay workstream
  #      fills in; until then there are no rows and the builder falls through.
  #   2. Otherwise, normalized capture THUMBNAILS in capture order
  #      (artifacts/<job_id>/evidence/, rendered by the sidecar on demand).
  #
  # Degrades to [] on any sidecar/minter failure — the evidence strip is omitted,
  # never a 5xx (the partial renders nothing for an empty list).
  def evidence_photos_for(measurement)
    composites = composite_evidence_photos
    return composites.first(EVIDENCE_PHOTO_CAP) unless composites.empty?

    thumbnail_evidence_photos.first(EVIDENCE_PHOTO_CAP)
  rescue SidecarClient::Error, ArtifactUrlMinter::Error => e
    Rails.logger.warn("[ReportPdf] evidence photos unavailable, omitting section: #{e.class}")
    []
  end

  # Projected composites from ProjectedOverlay rows, ordered most-pose-confident
  # first (a nil pose_confidence sorts last). Returns [] when the job has none.
  def composite_evidence_photos
    overlays = projected_overlays
    return [] if overlays.empty?

    overlays
      .sort_by { |o| -(o.pose_confidence || -Float::INFINITY) }
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

    capture_ids = Capture.joins(:capture_session)
                         .where(capture_sessions: { job_id: @job.id })
                         .select(:id)
    ProjectedOverlay.where(capture_id: capture_ids).includes(:capture).to_a
  rescue ActiveRecord::StatementInvalid
    []
  end

  # Normalized capture thumbnails in capture order, rendered by the sidecar on
  # demand. Returns [] when the job has no captures.
  def thumbnail_evidence_photos
    photos = capture_photo_specs
    return [] if photos.empty?

    response = SidecarClient.render_evidence_thumbnails(job_id: @job.id, photos: photos)
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

    Capture.joins(:capture_session)
           .where(capture_sessions: { job_id: @job.id })
           .where.not(photo_ref: nil)
           .order(:sequence_index)
           .map do |capture|
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

  # Page-number chrome ("Page N of M") in the printed footer. Rendered by
  # Chromium's displayHeaderFooter footer band, which lives inside the @page
  # bottom margin (0.875in in report.css) — below the content box, so it does
  # not collide with the fixed `.report-attribution` strip that sits at the
  # bottom of the content box. An empty headerTemplate suppresses the default
  # Chromium header (date/title) that displayHeaderFooter would otherwise show.
  FOOTER_TEMPLATE = <<~HTML.freeze
    <div style="width:100%;font-size:8px;color:#6B7280;font-family:sans-serif;text-align:center;padding:0 0.75in;">
      Page <span class="pageNumber"></span> of <span class="totalPages"></span>
    </div>
  HTML

  # Containerized Chromium needs --no-sandbox; print-media keeps the report's
  # print CSS authoritative. Centralized in the initializer as defaults; the
  # page-number footer band is added here.
  def grover_options
    {
      display_header_footer: true,
      header_template: "<span></span>",
      footer_template: FOOTER_TEMPLATE,
      # displayHeaderFooter needs a non-zero bottom margin for the footer band to
      # be visible; match the @page bottom margin from report.css so the content
      # box is unchanged from the marginless base render.
      margin: { top: "0", bottom: "0.875in", left: "0", right: "0" }
    }
  end
end
