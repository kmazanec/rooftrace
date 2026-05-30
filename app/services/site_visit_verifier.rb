# Determines whether a completed capture session constitutes a GPS-verified
# site visit, computing the great-circle proximity of each capture's recorded
# GPS fix to the measurement's geocoded address.
#
# Used by ReportPdf (and only ReportPdf) to produce the `visit_verification`
# hash that drives the claim-PDF site-visit block (ADR-018).
#
# HONESTY: the "GPS-verified within N m of the geocoded address" claim is an
# assertion in an insurance document. It is made ONLY when at least one
# capture's recorded GPS fix actually falls within VISIT_RADIUS_M of the
# geocoded address coordinates. Missing GPS or a too-distant nearest fix
# yields gps_verified: false, and the partial softens the wording rather than
# asserting an unverified fact.
class SiteVisitVerifier
  # The "within N m of the geocoded address" radius (meters). Configurable via
  # CLAIM_PDF_VISIT_RADIUS_M; defaults to 12 m. Named as a constant so the
  # default is not a magic literal scattered across methods.
  VISIT_RADIUS_M = (ENV["CLAIM_PDF_VISIT_RADIUS_M"].presence&.to_i || 12).freeze

  # Earth radius (meters) for the great-circle distance below.
  EARTH_RADIUS_M = 6_371_000.0

  # Builds the site-visit verification summary for the claim PDF (ADR-018), or
  # nil when there is no completed capture session.
  #
  # @param capture_session [CaptureSession, nil]
  # @param measurement     [Measurement]
  # @return [Hash, nil]
  #   { photo_count:, visit_time:, radius_m:, gps_verified:, distance_m: }
  def visit_verification_for(capture_session, measurement)
    return nil if capture_session.nil?

    ended_at = capture_session.ended_at || capture_session.started_at || Time.current
    distance_m = nearest_capture_distance_m(capture_session, measurement)

    {
      photo_count: capture_session.captures.count,
      visit_time: ended_at.strftime("%Y-%m-%d %H:%M %Z"),
      radius_m: VISIT_RADIUS_M,
      gps_verified: distance_m.present? && distance_m <= VISIT_RADIUS_M,
      distance_m: distance_m&.round(1)
    }
  end

  private

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

  # Great-circle distance in meters between two WGS84 lat/lon points.
  def haversine_m(lat1, lon1, lat2, lon2)
    rad = Math::PI / 180.0
    dlat = (lat2 - lat1) * rad
    dlon = (lon2 - lon1) * rad
    a = (Math.sin(dlat / 2)**2) +
        (Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * (Math.sin(dlon / 2)**2))
    EARTH_RADIUS_M * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
  end
end
