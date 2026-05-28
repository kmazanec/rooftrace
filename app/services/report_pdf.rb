require "grover"

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

  def initialize(job, store: nil)
    @job = job
    @store = store || ArtifactStore.new
  end

  # @return [String] a signed https URL to the report PDF in Spaces.
  def render
    measurement = @job.latest_measurement
    raise Error, "job #{@job.id} has no measurement to render" if measurement.nil?

    cached = fresh_cached_pdf_url
    return cached if cached

    bbox = bbox_from_facets(measurement)
    map_image_url, fallback_warning = map_image_url_for(measurement, bbox)

    html = render_html(measurement, map_image_url:, fallback_warning:)
    pdf_bytes = Grover.new(html, **grover_options).to_pdf

    @store.put(key: pdf_key, body: pdf_bytes, content_type: "application/pdf")
    ArtifactUrlMinter.call(object_key: pdf_key)
  end

  private

  def pdf_key
    "artifacts/#{@job.id}/report.pdf"
  end

  def fresh_cached_pdf_url
    head = @store.head(pdf_key)
    return nil if head.nil?

    last_modified = head[:last_modified]
    return nil if last_modified.nil?
    return nil if last_modified < CACHE_WINDOW.ago

    ArtifactUrlMinter.call(object_key: pdf_key)
  end

  # Returns [signed_map_url, fallback_warning_message_or_nil]. The sidecar render
  # is the primary path; on any SidecarClient error we degrade to a Mapbox Static
  # image uploaded under artifacts/ and flag a warning for the footer.
  def map_image_url_for(measurement, bbox)
    response = SidecarClient.render_images(
      job_id: @job.id, bbox: bbox, width_px: MAP_WIDTH_PX, height_px: MAP_HEIGHT_PX
    )
    [ ArtifactUrlMinter.call(object_key: response.fetch("image_ref")), nil ]
  rescue SidecarClient::Error => e
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
  rescue MapboxStaticFallback::Error => e
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

  def render_html(measurement, map_image_url:, fallback_warning:)
    ApplicationController.render(
      template: "reports/show",
      formats: [ :pdf ],
      handlers: [ :erb ],
      layout: "report_print",
      assigns: {
        job: @job,
        measurement: measurement,
        map_image_url: map_image_url,
        fallback_warning: fallback_warning
      }
    )
  end

  # Containerized Chromium needs --no-sandbox; print-media + zero margins keep the
  # report's print CSS authoritative. Centralized in the initializer as defaults;
  # repeated here for the per-call instance.
  def grover_options
    {}
  end
end
