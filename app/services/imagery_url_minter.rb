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

    presigner.presigned_url(
      :get_object,
      bucket: @bucket,
      key: object_key,
      expires_in: expires_in.to_i
    )
  end

  private

  def presigner
    Aws::S3::Presigner.new(client: client)
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
