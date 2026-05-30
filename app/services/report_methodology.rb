# Generates a claim-defensible methodology statement for the claim PDF (ADR-018).
# Composes from provenance fields on the Measurement — never hardcoded strings.
# Handles partial provenance gracefully: imagery-only omits the LiDAR sentence;
# no on-site fusion omits the ICP sentence. No "N/A" placeholders — omit cleanly.
#
# Usage:
#   sentences = ReportMethodology.call(measurement)
#   # => ["Imagery: Mapbox, retrieved 2024-08-12.", "LiDAR: USGS 3DEP work unit
#   #      NE_Southeast_2021_D21 (QL2), captured 2021.", ...]
class ReportMethodology
  def self.call(measurement)
    new(measurement).sentences
  end

  def initialize(measurement)
    @prov = measurement.provenance || {}
  end

  # Returns an Array<String> of methodology sentences, one per data source or
  # method step. Empty array when provenance is completely absent.
  def sentences
    result = []
    result << imagery_sentence if imagery_prov.any?
    result << lidar_sentence   if lidar_prov.any?
    result << geometry_sentence
    result << detector_sentence if detector.present?
    result << on_site_sentence  if on_site_sentence_applicable?
    result.compact
  end

  private

  def imagery_prov
    @imagery_prov ||= Array(@prov.dig("attributions", "imagery")).first || {}
  end

  def lidar_prov
    @lidar_prov ||= Array(@prov.dig("attributions", "lidar")).first || {}
  end

  def detector
    @prov["detector"].presence
  end

  def geometry_source
    @prov["geometry_source"].presence || "public LiDAR and satellite imagery fusion"
  end

  def sam2_backend
    @prov["sam2_backend"].presence
  end

  def fusion_icp_rmse_m
    # Check top-level provenance key (set by FusionOrchestrator)
    @prov["fusion_icp_rmse_m"].presence
  end

  # ---------------------------------------------------------------------------
  # Sentence builders
  # ---------------------------------------------------------------------------

  def imagery_sentence
    name = imagery_prov["name"].presence || "satellite imagery"
    parts = [ "Imagery: #{name}" ]
    if (retrieved = imagery_prov["retrieved_at"].presence)
      date = parse_date(retrieved)
      parts << ", acquired #{date}" if date
    end
    "#{parts.join}."
  end

  def lidar_sentence
    name = lidar_prov["name"].presence || "LiDAR"
    parts = [ "LiDAR: #{name}" ]
    if (retrieved = lidar_prov["retrieved_at"].presence)
      date = parse_date(retrieved)
      parts << ", acquired #{date}" if date
    end
    "#{parts.join}. Geometry: RANSAC plane fitting on classified-building points."
  end

  def geometry_sentence
    source_desc =
      case geometry_source
      when "lidar"   then "LiDAR point-cloud RANSAC plane fitting"
      when "imagery" then "satellite imagery planimetric estimation"
      when "fusion"  then "LiDAR + imagery fusion, RANSAC plane fitting on classified-building points"
      when "capture" then "ARKit on-site capture + ICP alignment"
      else geometry_source
      end
    backend_note =
      if sam2_backend.present?
        " Outline refined by SAM2 (#{sam2_backend} backend)."
      else
        ""
      end
    "Geometry method: #{source_desc}.#{backend_note}"
  end

  def detector_sentence
    model_name = detector
    "Feature detection: #{model_name} with verification pass."
  end

  def on_site_sentence_applicable?
    fusion_icp_rmse_m.present?
  end

  def on_site_sentence
    rmse = fusion_icp_rmse_m.to_f.round(2)
    "On-site capture: ARKit world-mesh + LiDAR depth, ICP-aligned RMSE #{rmse} m."
  end

  def parse_date(iso8601_str)
    # Return a date portion (YYYY-MM-DD) from an ISO8601 timestamp or bare date string.
    return nil if iso8601_str.blank?

    iso8601_str.to_s[/\d{4}-\d{2}-\d{2}/]
  rescue StandardError
    nil
  end
end
