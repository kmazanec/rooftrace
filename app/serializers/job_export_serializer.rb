# Stateless transform from a Job (+ its latest_measurement) into the public JSON
# export shape (shared/json_export.schema.json, ADR-015). This is the first class
# in app/serializers/ and sets the pattern: a plain PORO (NOT ActiveModel::
# Serializer — that gem is not in the Gemfile), pure transform, no validation
# (the controller validates the result and 500s loudly on serializer drift).
#
# Three field-mapping facts diverge from the internal storage shape and are the
# whole reason this class exists (see shared/JSON_EXPORT_CONVENTIONS.md):
#   1. Facet vertices are stored WGS84 [lon, lat]; the export FLIPS them to
#      [lat, lng] to match insurance-tool convention. A silent failure to flip
#      ships subtly-wrong coordinates that still validate (both are numbers) — so
#      the flip has an explicit test.
#   2. predominant_pitch_degrees is DERIVED here from the stored ratio
#      (atan(ratio/12)); only the ratio is persisted.
#   3. geocode is stored as an Address {lon, lat, ...}; the export emits
#      {lat, lng, confidence} (renamed, not flipped values).
#
# Artifact URLs are INJECTED by the request-aware controller (no url_helpers with
# a hard-coded host here); model_3d_url is always null in v1 (3D deferred).
class JobExportSerializer
  def initialize(job, share_url: nil, pdf_url: nil)
    @job = job
    @share_url = share_url
    @pdf_url = pdf_url
  end

  def to_h
    {
      "schema_version" => JsonExportSchema.version,
      "job" => job_block,
      "measurement" => measurement_block,
      "provenance" => provenance_block,
      "artifacts" => artifacts_block
    }
  end

  private

  attr_reader :job, :share_url, :pdf_url

  def measurement
    @measurement ||= job&.latest_measurement
  end

  # A nil job (an orphaned share token whose Report.job is nil) still produces a
  # valid not-ready document per the frozen resolver contract (200-with-null,
  # never a 500): emit null id/address/status rather than raise.
  def job_block
    {
      "id" => job&.id,
      "address" => job&.address,
      "status" => job&.status
    }
  end

  # Null when the job hasn't produced a measurement yet (not-ready). The schema
  # permits a null measurement (200-with-null-artifacts, never a 500).
  def measurement_block
    return nil if measurement.nil?

    ratio = numeric(measurement.predominant_pitch_ratio)
    {
      "generated_at" => measurement.generated_at&.iso8601,
      "source" => measurement.source,
      "confidence" => numeric(measurement.confidence),
      "total_area_sq_ft" => numeric(measurement.total_area_sq_ft),
      "total_perimeter_ft" => numeric(measurement.total_perimeter_ft),
      "predominant_pitch_ratio" => ratio,
      "predominant_pitch_degrees" => degrees_from_ratio(ratio),
      "warnings" => Array(measurement.warnings),
      "facets" => Array(measurement.facets).map { |f| map_facet(f) },
      "features" => Array(measurement.features).map { |f| map_feature(f) },
      "geocode" => map_geocode(measurement.geocode)
    }
  end

  def map_facet(facet)
    {
      "facet_id" => facet["facet_id"],
      # FLIP each [lon, lat] vertex to [lat, lng]. Keep only the two horizontal
      # components (the internal vertex may carry an optional elevation).
      "vertices" => Array(facet["vertices"]).map { |lon, lat, *| [ lat, lon ] },
      "pitch_ratio" => numeric(facet["pitch_ratio"]),
      "pitch_degrees" => numeric(facet["pitch_degrees"]),
      "area_sq_ft" => numeric(facet["area_sq_ft"]),
      "source" => facet["source"],
      "confidence" => numeric(facet["confidence"])
    }
  end

  # bbox_norm is normalized image space against the satellite tile, so no
  # geographic center is derivable — none is emitted (documented v1 limitation).
  def map_feature(feature)
    {
      "label" => feature["label"],
      "bbox_norm" => Array(feature["bbox_norm"]),
      "verified" => feature["verified"],
      "source" => feature["source"],
      "confidence" => numeric(feature["confidence"])
    }
  end

  # The stored Address uses lon/lat; the export renames to lat/lng (insurance
  # convention). Null when no geocode was resolved.
  def map_geocode(geocode)
    return nil if geocode.blank?

    {
      "lat" => numeric(geocode["lat"]),
      "lng" => numeric(geocode["lon"]),
      "confidence" => numeric(geocode["confidence"])
    }
  end

  # Best-effort pass-through of the orchestrator's nested provenance. The schema
  # marks every provenance field optional (additionalProperties:true), so absent
  # keys simply don't appear. Null when no provenance was recorded.
  def provenance_block
    return nil if measurement.nil?

    prov = measurement.provenance
    prov.present? ? prov : nil
  end

  def artifacts_block
    {
      "pdf_url" => pdf_url,
      "share_url" => share_url,
      "model_3d_url" => nil
    }
  end

  # Degrees from a rise-per-12 ratio: atan(ratio / 12). Null when no ratio.
  def degrees_from_ratio(ratio)
    return nil if ratio.nil?

    (Math.atan(ratio / 12.0) * 180.0 / Math::PI).round(2)
  end

  # Coerce DB numerics (BigDecimal from numeric columns) to plain floats so the
  # JSON renders as numbers, not quoted decimal strings. nil passes through.
  def numeric(value)
    return nil if value.nil?

    value.to_f
  end
end
