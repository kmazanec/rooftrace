require "aws-sdk-s3"

# Mints a short-lived, signed HTTPS GET URL over a DigitalOcean Spaces object
# under the `artifacts/` key prefix (the rendered report PDF and map PNG).
#
# This is the `artifacts/`-prefix sibling of ImageryUrlMinter (which is
# hard-locked to the `cache/` prefix and RAISES on anything else). The two are
# deliberately separate so neither can mint a URL over the other's partition of
# the one key-prefixed Spaces bucket (ADR-010 as amended): a report surface must
# never be able to sign a `cache/` imagery tile, and the imagery pipeline must
# never be able to sign an `artifacts/` report blob.
class ArtifactUrlMinter
  class Error < StandardError; end

  # Default lifetime of a minted URL. Bounded so a leaked report-download link
  # stops working within a day, while still surviving a normal share/download
  # session.
  DEFAULT_EXPIRES_IN = 24.hours

  # Report artifacts (PDF, map PNG) live under the `artifacts/` key prefix of the
  # one partitioned bucket (ADR-010). Asserting the prefix is defense-in-depth: a
  # future caller bug must not be able to mint a public URL over `uploads/`
  # (user-supplied photos), `cache/`, or `backups/`.
  ALLOWED_KEY_PREFIX = "artifacts/".freeze

  def self.call(object_key:, expires_in: DEFAULT_EXPIRES_IN)
    new.call(object_key: object_key, expires_in: expires_in)
  end

  def initialize(client: nil, bucket: nil)
    @client = client
    @bucket = bucket || ENV.fetch("STORAGE_BUCKET", "rooftrace")
  end

  # @param object_key [String] Spaces key, e.g. "artifacts/<job_id>/report.pdf".
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
    @client ||= Aws::S3::Client.new(
      access_key_id: ENV.fetch("STORAGE_ACCESS_KEY"),
      secret_access_key: ENV.fetch("STORAGE_SECRET_KEY"),
      endpoint: ENV.fetch("STORAGE_ENDPOINT"),
      region: ENV.fetch("STORAGE_REGION", "us-east-1"),
      force_path_style: false
    )
  end
end
