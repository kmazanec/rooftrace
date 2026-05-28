require "aws-sdk-s3"
require "securerandom"

# Per-bucket write/read/delete probe for the four DigitalOcean Spaces buckets
# (ADR-010). Surfaced through /health so deploy fails fast when Spaces creds
# drift — per F-01 acceptance: "Spaces connectivity test: part of /health's
# body should report write+read success against each bucket".
class SpacesHealth
  BUCKETS = %w[uploads cache artifacts backups].freeze

  Result = Struct.new(:bucket, :ok, :error, keyword_init: true) do
    def to_h
      ok ? "ok" : "fail: #{error}"
    end
  end

  def self.check_all
    new.check_all
  end

  def initialize(client: default_client, prefix: ENV.fetch("SPACES_HEALTH_PREFIX", "_health"))
    @client = client
    @prefix = prefix
  end

  def check_all
    BUCKETS.each_with_object({}) do |bucket, results|
      results[bucket] = probe(bucket).to_h
    end
  end

  def ok?(results)
    results.values.all? { |v| v == "ok" }
  end

  private

  def probe(bucket_suffix)
    bucket = "rooftrace-#{bucket_suffix}"
    key = "#{@prefix}/#{SecureRandom.uuid}"

    @client.put_object(bucket: bucket, key: key, body: "ok", content_type: "text/plain")
    body = @client.get_object(bucket: bucket, key: key).body.read
    raise "read mismatch" unless body == "ok"

    Result.new(bucket: bucket_suffix, ok: true, error: nil)
  rescue StandardError => e
    Result.new(bucket: bucket_suffix, ok: false, error: e.message[0, 200])
  ensure
    @client.delete_object(bucket: bucket, key: key) rescue nil
  end

  def default_client
    Aws::S3::Client.new(
      access_key_id: ENV.fetch("STORAGE_ACCESS_KEY"),
      secret_access_key: ENV.fetch("STORAGE_SECRET_KEY"),
      endpoint: ENV.fetch("STORAGE_ENDPOINT"),
      region: ENV.fetch("STORAGE_REGION", "us-east-1"),
      force_path_style: false
    )
  end
end
