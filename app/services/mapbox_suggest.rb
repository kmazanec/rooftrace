require "net/http"
require "json"

# Rails-side client for the Mapbox Search Box "suggest" endpoint, powering the
# address-entry typeahead. ADR-004 (amended): Mapbox provides IN-SESSION,
# NON-PERSISTED address suggestions only; Nominatim remains the authoritative
# geocoder. We deliberately call /suggest ONLY — never /retrieve — so we never
# obtain or store a Mapbox geocode, which keeps us clear of the Mapbox ToS
# storage restriction that drove ADR-004's choice of Nominatim (whose ODbL
# terms DO permit the geocode cache the pipeline relies on).
#
# This is a contractor-facing UI helper, NOT pipeline/geometry work, so it lives
# in Rails (ADR-008 boundary) and never touches the sidecar.
#
# Testability: like SidecarClient, the HTTP boundary is injectable (`http:`), so
# specs stub it without a new gem. The token is read from MAPBOX_PRIVATE_TOKEN —
# the single server-side Mapbox token shared by all server-side Mapbox calls
# (imagery, map render, PDF fallback, this). The browser-only viewer basemap uses
# MAPBOX_PUBLIC_TOKEN instead; the split is by exposure, not by feature.
#
# Resilience: autocomplete is a progressive enhancement. Any failure (missing
# token, Mapbox error, timeout, malformed body) returns an EMPTY list — never
# raises — so the address field stays a working plain text input.
class MapboxSuggest
  SUGGEST_URL = "https://api.mapbox.com/search/searchbox/v1/suggest".freeze
  MIN_QUERY_LENGTH = 4
  DEFAULT_LIMIT = 6
  OPEN_TIMEOUT = 2  # seconds — this is keystroke-latency-sensitive
  READ_TIMEOUT = 3

  Suggestion = Struct.new(:name, :mapbox_id, :place_formatted, keyword_init: true)

  # http: any object responding to #start like Net::HTTP (injected in tests).
  def initialize(token: nil, http: Net::HTTP, logger: Rails.logger)
    @token = (token || ENV["MAPBOX_PRIVATE_TOKEN"]).to_s.strip
    @http = http
    @logger = logger
  end

  # Returns an Array<Suggestion>. Always returns an array; never raises.
  def suggest(query, session_token:, limit: DEFAULT_LIMIT)
    query = query.to_s.strip
    return [] if query.length < MIN_QUERY_LENGTH
    return [] if @token.empty?

    body = fetch(query, session_token: session_token, limit: limit)
    return [] if body.nil?

    parse(body)
  rescue StandardError => e
    @logger&.warn("[mapbox_suggest] #{e.class}: #{e.message}")
    []
  end

  private

  def fetch(query, session_token:, limit:)
    uri = URI(SUGGEST_URL)
    uri.query = URI.encode_www_form(
      q: query,
      access_token: @token,
      session_token: session_token.to_s,
      country: "us",
      types: "address",
      language: "en",
      limit: limit
    )

    res = @http.start(uri.host, uri.port, use_ssl: true,
                      open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
      http.get(uri.request_uri)
    end

    code = res.code.to_i
    if code.between?(200, 299)
      res.body
    else
      @logger&.warn("[mapbox_suggest] Mapbox HTTP #{code}")
      nil
    end
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    @logger&.warn("[mapbox_suggest] timeout: #{e.message}")
    nil
  end

  def parse(body)
    json = JSON.parse(body)
    Array(json["suggestions"]).filter_map do |s|
      name = s["name"].presence
      next unless name

      Suggestion.new(
        name: name,
        mapbox_id: s["mapbox_id"],
        place_formatted: s["place_formatted"]
      )
    end
  end
end
