require "aws-sdk-s3"

# Thin read/write wrapper over the DigitalOcean Spaces `artifacts/` partition of
# the one key-prefixed bucket (ADR-010). The report PDF pipeline uses it to
#   - `head` the existing report.pdf object (idempotency: re-use a fresh render),
#   - `put` the rendered PDF and the fallback map PNG.
#
# Like ArtifactUrlMinter, it asserts the `artifacts/` key prefix as
# defense-in-depth so a caller bug can never write into `uploads/` (user photos),
# `cache/` (imagery tiles), or `backups/`.
class ArtifactStore
  class Error < StandardError; end

  ALLOWED_KEY_PREFIX = "artifacts/".freeze

  def initialize(client: nil, bucket: nil)
    @client = client
    @bucket = bucket || ENV.fetch("STORAGE_BUCKET", "rooftrace")
  end

  # @return [Hash, nil] { last_modified: Time, metadata: Hash } for an existing
  #   object, or nil when the object does not exist OR any Spaces error occurs.
  #   `metadata` carries the object's user metadata (e.g. the degraded-render
  #   flag) so callers can distinguish a clean cache entry from a degraded one.
  #   The head is only an idempotency probe, so treating any S3 error (403/503/
  #   throttling/outage) as a cache miss is safe — the caller re-renders — and
  #   keeps the raw AWS message (which carries bucket/key/credentials) out of any
  #   user-facing 500 on the public PDF endpoint. ServiceError is the base class
  #   for every S3 error, so this also covers NotFound/NoSuchKey.
  def head(key)
    assert_prefix!(key)
    resp = client.head_object(bucket: @bucket, key: key)
    { last_modified: resp.last_modified, metadata: resp.metadata || {} }
  rescue Aws::S3::Errors::ServiceError
    nil
  end

  # @param metadata [Hash] optional user metadata stored on the object (S3
  #   x-amz-meta-* headers); used to tag a degraded render so it is not reused.
  # @return [true]
  def put(key:, body:, content_type:, metadata: {})
    assert_prefix!(key)
    client.put_object(
      bucket: @bucket, key: key, body: body, content_type: content_type,
      metadata: metadata
    )
    true
  end

  private

  def assert_prefix!(key)
    raise Error, "key is blank" if key.to_s.strip.empty?
    return if key.start_with?(ALLOWED_KEY_PREFIX)

    raise Error, "key must be under the #{ALLOWED_KEY_PREFIX} prefix, got: #{key.inspect}"
  end

  def client
    @client ||= SpacesClient.build
  end
end
