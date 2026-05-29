require "aws-sdk-s3"
require "fileutils"

# Writes iOS capture blobs (the ARKit world-mesh OBJ, per-prompt photos + depth
# maps, and the raw session.json) into the `uploads/` partition of the one
# key-prefixed Spaces bucket (ADR-010). The sidecar's fusion stage later resolves
# these same keys via its own storage.py.
#
# Prefix-locked to `uploads/` (defense-in-depth, mirroring ArtifactStore's
# `artifacts/` lock): a controller bug can never write user uploads into
# `cache/`, `artifacts/`, or `backups/`.
#
# Two backends, selected by environment so tests/dev need no live Spaces — the
# SAME split the sidecar's storage.py uses:
#   * Local (STORAGE_LOCAL_ROOT set): write the key as a path under that root.
#   * Live (otherwise): Aws::S3::Client#put_object, streaming the IO body
#     (Aws reads the IO in chunks; we never slurp the whole file into memory).
class SpacesUploader
  class Error < StandardError; end

  ALLOWED_KEY_PREFIX = "uploads/".freeze

  def initialize(client: nil, bucket: nil, local_root: nil)
    @client = client
    @bucket = bucket || ENV.fetch("STORAGE_BUCKET", "rooftrace")
    @local_root = local_root || ENV["STORAGE_LOCAL_ROOT"]
  end

  # @param key [String] the `uploads/...` object key
  # @param body [IO, #read] the blob source, streamed not slurped
  # @param content_type [String]
  # @return [String] the written key
  def put(key:, body:, content_type:)
    assert_prefix!(key)

    if @local_root.present?
      write_local(key, body)
    else
      client.put_object(bucket: @bucket, key: key, body: body, content_type: content_type)
    end
    key
  end

  private

  # Local-root write mirrors the sidecar storage.py local mode (and its
  # path-escape guard): the key is joined under the resolved root and any key
  # that would escape the root (`../`) is refused.
  def write_local(key, body)
    root = Pathname.new(@local_root).realpath
    path = (root + key).cleanpath
    unless path.to_s == root.to_s || path.to_s.start_with?("#{root}/")
      raise Error, "object key escapes storage root: #{key.inspect}"
    end

    FileUtils.mkdir_p(path.dirname)
    File.open(path, "wb") do |f|
      body.rewind if body.respond_to?(:rewind)
      IO.copy_stream(body, f)
    end
  end

  def assert_prefix!(key)
    raise Error, "key is blank" if key.to_s.strip.empty?
    return if key.start_with?(ALLOWED_KEY_PREFIX)

    raise Error, "key must be under the #{ALLOWED_KEY_PREFIX} prefix, got: #{key.inspect}"
  end

  def client
    @client ||= Aws::S3::Client.new(
      access_key_id: ENV.fetch("STORAGE_ACCESS_KEY"),
      secret_access_key: ENV.fetch("STORAGE_SECRET_KEY"),
      endpoint: ENV.fetch("STORAGE_ENDPOINT"),
      region: ENV.fetch("STORAGE_REGION", "us-east-1"),
      force_path_style: false
    )
  end
end
