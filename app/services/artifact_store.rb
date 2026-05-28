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

  # @return [Hash, nil] { last_modified: Time } for an existing object, or nil
  #   when the object does not exist. Other AWS errors propagate.
  def head(key)
    assert_prefix!(key)
    resp = client.head_object(bucket: @bucket, key: key)
    { last_modified: resp.last_modified }
  rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
    nil
  end

  # @return [true]
  def put(key:, body:, content_type:)
    assert_prefix!(key)
    client.put_object(bucket: @bucket, key: key, body: body, content_type: content_type)
    true
  end

  private

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
