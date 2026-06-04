# Pure transforms that fold the per-stage pipeline outputs into the unified
# Measurement contract entity (and its row-only companions). No I/O, no Job
# mutation, no thread state — every input is an explicit argument so each
# transform is independently testable.
#
# The orchestrator owns sequencing + persistence and calls into here to build
# the validated Measurement document, compute the overall confidence, collect the
# merged warnings, and assemble the provenance record.
class MeasurementAssembler
  # Overall confidence is the product of the stage confidences we have
  # (geocode * geometry), so any weak stage drags the whole number down —
  # honest-uncertainty rule. The fallback (imagery-only) path additionally caps
  # the result so an imagery-only measurement can never read as confident as a
  # fused one even if the individual stages were optimistic.
  IMAGERY_CONFIDENCE_CAP = 0.6

  # Assemble the schema `Measurement` entity (the cross-service contract shape).
  # job_id + facets + features + source + confidence are required; the polygons
  # and roll-ups are optional and included when present.
  def build_measurement_document(job_id:, footprint:, roof_outline:, lidar:,
                                 geometry:, features:, source:, confidence:)
    doc = {
      "job_id" => job_id,
      "facets" => Array(geometry["facets"]),
      "features" => Array(features),
      "source" => source,
      "confidence" => confidence
    }
    doc["footprint"] = footprint if footprint
    doc["roof_outline"] = roof_outline if roof_outline
    doc["lidar"] = lidar if lidar
    unless geometry["total_area_sq_ft"].nil?
      doc["total_area_sq_ft"] = geometry["total_area_sq_ft"]
    end
    unless geometry["primary_pitch_ratio"].nil?
      doc["predominant_pitch_ratio"] = geometry["primary_pitch_ratio"]
    end
    doc
  end

  # The assembled Measurement is a cross-service contract entity; validating it
  # before persistence catches Rails-side composition drift (e.g. a stage shape
  # that changed under us) loudly rather than writing a malformed row.
  def validate_measurement!(doc)
    errors = PipelineSchema.errors_for("Measurement", doc)
    return if errors.empty?

    raise SidecarClient::SchemaError,
          "Measurement assembly validation failed (contract drift?): #{errors.join('; ')}"
  end

  def overall_confidence(resolve:, geometry:, lidar_available:)
    geocode_conf = resolve.dig("geocode", "confidence")
    geometry_conf = geometry["confidence"]
    factors = [ geocode_conf, geometry_conf ].compact.map(&:to_f)
    # An empty product is the multiplicative identity (1.0), not zero.
    combined = factors.empty? ? 1.0 : factors.inject(:*)
    combined = [ combined, IMAGERY_CONFIDENCE_CAP ].min unless lidar_available
    combined.clamp(0.0, 1.0).round(4)
  end

  # Merge the orchestrator's accumulated warnings (lidar_missing, vlm_failed, ...)
  # with the per-stage warnings each sidecar response carried.
  def collect_warnings(accumulated:, imagery:, refined:, geometry:)
    (accumulated +
      Array(imagery["warnings"]) +
      Array(refined["warnings"]) +
      Array(geometry["warnings"])).uniq
  end

  # Provenance records the data-source attributions each stage returned, the
  # detector identity, and the schema version, so downstream surfaces can render
  # the attribution the data licenses require. It also captures the acquisition
  # vintage of the source data (LiDAR work-unit year/quality-level and the
  # per-stage retrieved_at timestamps) so a report can state how current the
  # underlying data is.
  def build_provenance(resolve:, imagery:, lidar_response:, refined:, geometry:)
    {
      "pipeline_schema_version" => PipelineSchema.version,
      "detector" => FeatureDetector.detector_name,
      "sam2_backend" => refined["sam2_backend"],
      "geometry_source" => geometry["source"],
      "roof_model" => geometry["roof_model"],
      "lidar_work_unit" => lidar_work_unit(lidar_response),
      "attributions" => {
        "resolve_address" => resolve["attribution"],
        "imagery" => imagery["attribution"],
        "lidar" => lidar_response["attribution"]
      }.compact,
      "retrieved_at" => {
        "resolve_address" => first_retrieved_at(resolve["attribution"]),
        "imagery" => first_retrieved_at(imagery["attribution"]),
        "lidar" => first_retrieved_at(lidar_response["attribution"])
      }.compact,
      "generated_at" => Time.current.iso8601
    }.compact
  end

  # The LiDAR work-unit's acquisition year + survey quality level, when the
  # ingest-lidar stage reported coverage (nil on the no-LiDAR fallback path).
  def lidar_work_unit(lidar_response)
    work_unit = lidar_response.dig("lidar", "work_unit")
    return nil if work_unit.nil?

    {
      "name" => work_unit["name"],
      "year" => work_unit["year"],
      "quality_level" => work_unit["quality_level"]
    }.compact.presence
  end

  # The retrieved_at of a stage's first attribution entry, when present.
  def first_retrieved_at(attribution)
    Array(attribution).filter_map { |a| a["retrieved_at"] }.first
  end
end
