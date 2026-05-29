# Validates an iOS capture session.json manifest before any blob is uploaded or
# any row is persisted (ADR-007: the iOS app is a thin client; the server owns
# trust). A plain-Ruby value object — no external schema gem — that checks the
# load-bearing fields the ingest path depends on:
#   * session_id present (the idempotency key),
#   * manifest_version with a supported MAJOR version (we accept 1.x only; a
#     future breaking manifest bumps the major and is rejected here, not silently
#     mis-parsed),
#   * gps_origin present with the coarse-ICP-seed fields (the alignment seed —
#     missing GPS means fusion can't place the ARKit mesh),
#   * a non-empty, bounded captures array,
#   * world_mesh.filename == 'arkit_mesh.obj' and .format == 'obj' (the mesh the
#     sidecar ICP-aligns).
#
# The machine-readable contract is shared/ios_session_schema.json; this validator
# mirrors its required fields. Returns { valid: Boolean, errors: [String] }.
class SessionManifestValidator
  SUPPORTED_MANIFEST_MAJOR = "1".freeze

  # The guided walk-around is exactly 8 prompts; cap the captures array so a
  # malformed/hostile manifest can't make us iterate an unbounded list (the
  # bytes were already size-capped at the controller, but a manifest with a huge
  # captures array inside a small JSON is still a DoS shape worth rejecting).
  MAX_CAPTURES = 8

  GPS_ORIGIN_FIELDS = %w[
    latitude longitude altitude_m horizontal_accuracy_m vertical_accuracy_m
  ].freeze

  def self.call(manifest)
    new(manifest).call
  end

  def initialize(manifest)
    @manifest = manifest
    @errors = []
  end

  def call
    unless @manifest.is_a?(Hash)
      return result([ "manifest is not a JSON object" ])
    end

    validate_session_id
    validate_manifest_version
    validate_gps_origin
    validate_captures
    validate_world_mesh

    result(@errors)
  end

  private

  def validate_session_id
    @errors << "session_id is required" if @manifest["session_id"].to_s.strip.empty?
  end

  def validate_manifest_version
    version = @manifest["manifest_version"].to_s
    if version.strip.empty?
      @errors << "manifest_version is required"
      return
    end

    major = version.split(".", 2).first
    unless major == SUPPORTED_MANIFEST_MAJOR
      @errors << "unsupported manifest_version #{version.inspect} " \
                 "(this server understands #{SUPPORTED_MANIFEST_MAJOR}.x)"
    end
  end

  def validate_gps_origin
    gps = @manifest["gps_origin"]
    unless gps.is_a?(Hash)
      @errors << "gps_origin is required"
      return
    end

    missing = GPS_ORIGIN_FIELDS.reject { |f| gps.key?(f) && !gps[f].nil? }
    @errors << "gps_origin is missing: #{missing.join(', ')}" if missing.any?
  end

  def validate_captures
    captures = @manifest["captures"]
    unless captures.is_a?(Array) && captures.any?
      @errors << "captures must be a non-empty array"
      return
    end

    if captures.length > MAX_CAPTURES
      @errors << "captures exceeds the maximum of #{MAX_CAPTURES} (#{captures.length} given)"
    end
  end

  def validate_world_mesh
    mesh = @manifest["world_mesh"]
    unless mesh.is_a?(Hash)
      @errors << "world_mesh is required"
      return
    end

    if mesh["filename"] != "arkit_mesh.obj"
      @errors << "world_mesh.filename must be 'arkit_mesh.obj'"
    end
    if mesh["format"] != "obj"
      @errors << "world_mesh.format must be 'obj'"
    end
  end

  def result(errors)
    { valid: errors.empty?, errors: errors }
  end
end
