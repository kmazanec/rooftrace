require "aws-sdk-s3"

# Mints a short-lived, signed HTTPS GET URL over a DigitalOcean Spaces object
# key (the imagery `cache/` tile the render-imagery stage produced).
#
# Why this exists (SSRF boundary, per the ROADMAP "Outbound-URL SSRF" rule):
# the VLM detector (FeatureDetector) hands the image URL to Gemini, which fetches
# it server-side. A caller-supplied URL is an SSRF surface (cloud-metadata,
# loopback, internal hosts). We therefore NEVER pass a caller URL: the pipeline
# carries blobs as Spaces object keys (the "blob-reference convention"), and the
# orchestrator mints a signed URL over OUR OWN object at the moment a stage needs
# the bytes. The URL points at the Spaces host (an allowlisted suffix in
# FeatureDetector's IMAGE_TILE_HOST_ALLOWLIST), is https, and expires quickly, so
# it is safe to hand to an external fetcher.
class ImageryUrlMinter
  class Error < StandardError; end

  # Default lifetime of a minted URL. Long enough to cover a slow VLM call,
  # short enough that a leaked URL is useless quickly.
  DEFAULT_EXPIRES_IN = 15.minutes

  # The pipeline only ever mints over derived imagery, which lives under the
  # `cache/` key prefix of the one partitioned bucket (ADR-010). Asserting the
  # prefix is defense-in-depth: a future caller bug must not be able to mint a
  # public URL over `uploads/` (user-supplied photos) or `backups/`.
  ALLOWED_KEY_PREFIX = "cache/".freeze

  def self.call(object_key:, expires_in: DEFAULT_EXPIRES_IN)
    new.call(object_key: object_key, expires_in: expires_in)
  end

  def initialize(client: nil, bucket: nil)
    @client = client
    @bucket = bucket || ENV.fetch("STORAGE_BUCKET", "rooftrace")
  end

  # @param object_key [String] Spaces key, e.g. "cache/imagery/<hash>.png".
  # @param expires_in [ActiveSupport::Duration, Integer] URL lifetime.
  # @return [String] a signed https GET URL.
  def call(object_key:, expires_in: DEFAULT_EXPIRES_IN)
    raise Error, "object_key is blank" if object_key.to_s.strip.empty?
    unless object_key.start_with?(ALLOWED_KEY_PREFIX)
      raise Error, "object_key must be under the #{ALLOWED_KEY_PREFIX} prefix, got: #{object_key.inspect}"
    end

    presigner.presigned_url(
      :get_object,
      bucket: @bucket,
      key: object_key,
      expires_in: expires_in.to_i
    )
  end

  private

  def presigner
    @presigner ||= Aws::S3::Presigner.new(client: client)
  end

  def client
    @client ||= SpacesClient.build
  end
end
