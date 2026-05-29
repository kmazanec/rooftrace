class Measurement < ApplicationRecord
  belongs_to :job

  # Keys the fusion stage records into the free-form `provenance` jsonb so a later
  # photo-projection stage can reuse the SOLVED fusion transform (ARKit capture
  # frame -> local UTM) rather than re-solving it from the mesh. These are
  # additive to the existing provenance blob; the public json_export provenance is
  # additionalProperties:true and these keys are NOT in its allowlist, so they
  # never leak to the export. See the fusion fields on `FuseCaptureResponse` in
  # shared/pipeline_schema.json.
  FUSION_ARKIT_TO_UTM_KEY = "fusion_arkit_to_utm_4x4".freeze
  FUSION_UTM_EPSG_KEY = "fusion_utm_epsg".freeze

  # The solved [16-float] row-major ARKit->UTM transform recorded at fusion time,
  # or nil if this measurement was not produced by an ICP-converged fusion.
  def fused_arkit_to_utm
    prov = provenance
    return nil unless prov.is_a?(Hash)

    value = prov[FUSION_ARKIT_TO_UTM_KEY]
    value if value.is_a?(Array) && value.length == 16
  end

  # The EPSG of the local UTM CRS the fused transform maps into, or nil.
  def fused_utm_epsg
    prov = provenance
    return nil unless prov.is_a?(Hash)

    prov[FUSION_UTM_EPSG_KEY]
  end
end
