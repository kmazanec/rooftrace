require "net/http"
require "uri"

# Degraded-but-not-broken roof-diagram path for the PDF (ADR-014 failure mode):
# when the sidecar's headless map render is unavailable, fetch a static
# satellite image from the Mapbox Static Images API instead, so the report still
# carries a roof diagram (with a warning footer that it is a degraded view).
#
# SSRF-safety: the bbox is validated to be WGS84-sane (and min < max) BEFORE the
# URL is built, and only the numeric coordinates + integer dimensions are
# interpolated into a fixed Mapbox host/path. No caller-supplied string ever
# reaches the URL, so the request can only ever hit api.mapbox.com.
class MapboxStaticFallback
  class Error < StandardError; end

  HOST = "api.mapbox.com".freeze
  STYLE = "mapbox/satellite-v9".freeze
  # Mapbox Static Images API caps a single image at 1280x1280.
  MAX_DIM = 1280
  # TCP connection timeout for the Mapbox Static Images API request.
  OPEN_TIMEOUT = 5
  # Socket read timeout; a 1280x1280@2x PNG is ~300-500 KB, well within 10 s.
  READ_TIMEOUT = 10

  def self.call(bbox:, width_px:, height_px:, token: nil)
    new(token: token).call(bbox: bbox, width_px: width_px, height_px: height_px)
  end

  def initialize(token: nil)
    @token = token || ENV["MAPBOX_PRIVATE_TOKEN"]
  end

  # @return [String] PNG bytes of the static satellite image.
  def call(bbox:, width_px:, height_px:)
    raise Error, "MAPBOX_PRIVATE_TOKEN is unset" if @token.to_s.strip.empty?

    min_lon, min_lat, max_lon, max_lat = validate_bbox!(bbox)
    w = clamp_dim(width_px)
    h = clamp_dim(height_px)

    uri = build_uri(min_lon, min_lat, max_lon, max_lat, w, h)
    fetch(uri)
  end

  private

  # Validates WGS84 range + ordering, returning the four floats. Raises before
  # any URL is constructed so an out-of-range coordinate cannot be interpolated.
  def validate_bbox!(bbox)
    unless bbox.is_a?(Array) && bbox.length == 4 && bbox.all? { |c| c.is_a?(Numeric) }
      raise Error, "bbox must be 4 numeric WGS84 coords"
    end

    min_lon, min_lat, max_lon, max_lat = bbox.map(&:to_f)
    in_range =
      min_lon.between?(-180.0, 180.0) && max_lon.between?(-180.0, 180.0) &&
      min_lat.between?(-90.0, 90.0) && max_lat.between?(-90.0, 90.0)
    unless in_range && min_lon < max_lon && min_lat < max_lat
      raise Error, "bbox out of WGS84 range or inverted: #{bbox.inspect}"
    end

    [ min_lon, min_lat, max_lon, max_lat ]
  end

  def clamp_dim(dim)
    Integer(dim).clamp(1, MAX_DIM)
  end

  def build_uri(min_lon, min_lat, max_lon, max_lat, width, height)
    # Mapbox's Static Images API expects the bbox as a literal
    # "[min_lon,min_lat,max_lon,max_lat]" path segment (brackets + commas), which
    # URI::HTTPS.build rejects as path components. The coordinates are already
    # validated to be plain numbers and the dimensions are integers, so building
    # the URL string by hand here introduces no injection surface — only numeric
    # values reach the path, and the query is properly encoded.
    # Percent-encode the brackets so URI.parse accepts the path; Mapbox decodes
    # them back to a literal bbox segment.
    bbox_segment = "%5B#{min_lon},#{min_lat},#{max_lon},#{max_lat}%5D"
    query = URI.encode_www_form(access_token: @token, attribution: "false", logo: "false")
    URI.parse(
      "https://#{HOST}/styles/v1/#{STYLE}/static/#{bbox_segment}/#{width}x#{height}@2x?#{query}"
    )
  end

  def fetch(uri)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                              open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
      http.get(uri.request_uri)
    end
    unless response.is_a?(Net::HTTPSuccess)
      raise Error, "Mapbox Static API returned #{response.code}"
    end

    response.body
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    raise Error, "Mapbox Static API timed out: #{e.message}"
  end
end
