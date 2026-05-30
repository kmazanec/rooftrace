# Computes all derived values that the reports/show.pdf.erb template needs,
# keeping the ERB scriptlet-free (pure markup + simple `<%= local %>` outputs).
#
# Instantiated by ReportPdf#render_html and consumed only via #to_assigns.
class PdfReportPresenter
  include ReportsHelper

  # Attribution names that MUST always appear in the footer regardless of what
  # a given pipeline run's provenance records (license-required static list,
  # per LICENSES.md).
  REQUIRED_ATTRIBUTIONS = [ "Mapbox", "USGS 3DEP", "MS Building Footprints", "Regrid", "Nominatim" ].freeze

  def initialize(job, measurement)
    @job = job
    @measurement = measurement
  end

  # Returns the normalized street address for display.
  def address
    geocode["normalized"].presence || geocode["raw"].presence || @job.address
  end

  # Geocoded lat string (rounded to 6 dp), or nil when not present.
  def geocode_lat
    v = geocode["lat"]
    v.present? ? v.to_f.round(6) : nil
  end

  # Geocoded lon string (rounded to 6 dp), or nil when not present.
  def geocode_lon
    v = geocode["lon"]
    v.present? ? v.to_f.round(6) : nil
  end

  # The stored predominant pitch rise/run ratio, or nil.
  def predominant_pitch_ratio
    @measurement.predominant_pitch_ratio
  end

  # Predominant pitch in degrees derived from the stored rise/run ratio, or nil.
  def predominant_pitch_degrees
    ratio = @measurement.predominant_pitch_ratio
    return nil unless ratio.present? && ratio.to_f.positive?

    (Math.atan(ratio.to_f / 12.0) * 180.0 / Math::PI).round(1)
  end

  def facets
    Array(@measurement.facets)
  end

  def features
    Array(@measurement.features)
  end

  # Returns the pitch label string "R/12 (D°)" for a single facet hash.
  def facet_pitch_label(f)
    fr = f["pitch_ratio"]
    fd = f["pitch_degrees"]
    fd = (Math.atan(fr.to_f / 12.0) * 180.0 / Math::PI).round(1) if fd.nil? && fr.present?
    if fr.present?
      "#{fr.to_f.round(1)}/12#{fd ? " (#{fd}°)" : ''}"
    else
      "—"
    end
  end

  # Maps a 0..1 confidence value to the honest-uncertainty band string.
  # Delegates to ReportsHelper#confidence_level (canonical, not duplicated).
  def conf_level(c)
    return "low" if c.nil?

    confidence_level(c)
  end

  # Feature rollup: Array<{ label:, count:, avg: }> sorted by count descending.
  def feature_rows
    features.group_by { |ft| ft["label"] }.map do |label, group|
      confs = group.filter_map { |ft| ft["confidence"]&.to_f }
      avg = confs.empty? ? nil : (confs.sum / confs.size)
      { label: label, count: group.size, avg: avg }
    end.sort_by { |r| -r[:count] }
  end

  # Union of license-required attribution names and provenance-supplied names.
  def attribution_names
    prov = @measurement.provenance || {}
    provenance_names =
      Array(prov["attributions"]).flat_map do |_stage, entries|
        Array(entries).filter_map { |e| e["name"] }
      end
    (REQUIRED_ATTRIBUTIONS + provenance_names).uniq
  end

  # The generated_at timestamp formatted for display, or "—" when nil.
  def generated_at_display(format)
    ts = @measurement.generated_at
    return "—" if ts.nil?

    ts.strftime(format)
  end

  private

  def geocode
    @geocode ||= @measurement.geocode || {}
  end
end
