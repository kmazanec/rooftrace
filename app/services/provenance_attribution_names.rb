# frozen_string_literal: true

# Flattens a provenance hash's per-stage attribution entries to a flat list of
# source names. Provenance shape: { "attributions" => { "imagery" => [{"name"=>..}], "lidar" => [..] } }.
#
# Both PdfReportPresenter and MeasurementViewerSerializer used divergent inline
# traversals that produced different results when a stage had >1 entry. This is
# the single correct implementation.
module ProvenanceAttributionNames
  module_function

  def call(provenance)
    return [] unless provenance.is_a?(Hash)

    attrs = provenance["attributions"]
    return [] unless attrs.is_a?(Hash)

    attrs.values.flat_map { |entries| Array(entries).filter_map { |e| e["name"] if e.is_a?(Hash) } }
  end
end
