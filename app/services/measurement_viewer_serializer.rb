# Server-side serializer for the interactive report viewer (ADR-013).
#
# This is DELIBERATELY NOT a route/API endpoint. The Hotwire report view bakes
# `as_json.to_json` into a data attribute the React island reads on connect, so:
#   - the unauthenticated public /r/:token view needs NO data fetch (no CORS /
#     SSRF surface to harden), and
#   - it cannot collide with the public measurement-JSON endpoints
#     (/api/v1/jobs/:id.json, /r/:token.json) owned by the JSON-export workstream
#     and governed by shared/json_export.schema.json.
#
# It emits ONLY what the island needs, derived from the real Measurement row.
# It does NOT reshape facets/features beyond selecting the frozen keys — there is
# no `id`, no `vertices_wgs84`; pitch_degrees IS stored per-facet (frozen Facet
# $def in shared/pipeline_schema.json). The only derivation is the predominant
# pitch in degrees (the row stores only the ratio) and the map bounds.
class MeasurementViewerSerializer
  # Frozen attribution source list (mirrors LICENSES.md). Used as a fallback when
  # a measurement's provenance carries no attributions.
  STATIC_ATTRIBUTIONS = [
    "NAIP",
    "USGS 3DEP",
    "Microsoft Building Footprints",
    "Regrid",
    "Mapbox",
    "Nominatim"
  ].freeze

  FACET_KEYS   = %w[facet_id vertices pitch_ratio pitch_degrees area_sq_ft source confidence].freeze
  FEATURE_KEYS = %w[label bbox_norm verified source confidence].freeze

  def initialize(measurement)
    @measurement = measurement
  end

  def as_json(*)
    {
      address: @measurement.job&.address,
      generated_at: @measurement.generated_at&.iso8601,
      source: @measurement.source,
      confidence: numeric(@measurement.confidence),
      total_area_sq_ft: numeric(@measurement.total_area_sq_ft),
      total_perimeter_ft: numeric(@measurement.total_perimeter_ft),
      primary_pitch_ratio: numeric(@measurement.predominant_pitch_ratio),
      primary_pitch_degrees: ratio_to_degrees(@measurement.predominant_pitch_ratio),
      bounds: bounds,
      facets: facets,
      features: features,
      roof_outline: @measurement.roof_outline,
      footprint: @measurement.footprint,
      warnings: Array(@measurement.warnings),
      attributions: attributions
    }
  end

  private

  def facets
    Array(@measurement.facets).map { |f| f.slice(*FACET_KEYS).symbolize_keys }
  end

  def features
    Array(@measurement.features).map { |f| f.slice(*FEATURE_KEYS).symbolize_keys }
  end

  # [minLon, minLat, maxLon, maxLat] across every facet vertex plus the
  # roof_outline / footprint rings, so the map can fitBounds on connect.
  def bounds
    points = []
    Array(@measurement.facets).each { |f| points.concat(Array(f["vertices"])) }
    points.concat(ring_points(@measurement.roof_outline))
    points.concat(ring_points(@measurement.footprint))
    points = points.select { |p| p.is_a?(Array) && p.size >= 2 }
    return nil if points.empty?

    lons = points.map { |p| p[0].to_f }
    lats = points.map { |p| p[1].to_f }
    [ lons.min, lats.min, lons.max, lats.max ]
  end

  def ring_points(geojson)
    return [] unless geojson.is_a?(Hash)

    coords = geojson["coordinates"]
    return [] unless coords.is_a?(Array)

    coords.flatten(1).select { |p| p.is_a?(Array) }
  end

  # The row stores only the ratio (rise per 12). Degrees is atan(ratio/12).
  def ratio_to_degrees(ratio)
    return nil if ratio.nil?

    (Math.atan(ratio.to_f / 12.0) * 180.0 / Math::PI).round(2)
  end

  def attributions
    names = provenance_attribution_names
    names.presence || STATIC_ATTRIBUTIONS.dup
  end

  def provenance_attribution_names
    prov = @measurement.provenance
    return [] unless prov.is_a?(Hash)

    attrs = prov["attributions"]
    return [] unless attrs.is_a?(Hash)

    attrs.values.filter_map do |a|
      a["name"] if a.is_a?(Hash)
    end
  end

  def numeric(value)
    value&.to_f
  end
end
