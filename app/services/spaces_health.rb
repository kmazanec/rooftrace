require "aws-sdk-s3"
require "securerandom"

# Write/read/delete probe for the DigitalOcean Spaces storage (ADR-010).
# Surfaced through /health so deploy fails fast when creds drift: the probe
# reports write+read success.
#
# STORAGE MODEL (ADR-010 as amended): rather than four separate
# buckets, RoofTrace uses ONE bucket (STORAGE_BUCKET) partitioned by key
# prefix — uploads/, cache/, artifacts/, backups/. The health probe writes a
# marker under each of the four prefixes so the four logical partitions are
# all exercised through a single bucket.
class SpacesHealth
  # The four logical storage partitions (key prefixes within the one bucket).
  PARTITIONS = %w[uploads cache artifacts backups].freeze
  # Kept as an alias because callers/specs reference BUCKETS for the partition
  # names; they're prefixes now, not bucket names.
  BUCKETS = PARTITIONS

  Result = Struct.new(:partition, :ok, :error, keyword_init: true) do
    # Public /health surface — return only "ok"/"fail", never the raw error
    # (AWS errors can carry the access key id, bucket, endpoint). The detailed
    # error is logged server-side by the caller.
    def to_h
      ok ? "ok" : "fail"
    end
  end

  def self.check_all
    new.check_all
  end

  def initialize(client: SpacesClient.build,
                 bucket: ENV.fetch("STORAGE_BUCKET", "rooftrace"),
                 prefix: ENV.fetch("SPACES_HEALTH_PREFIX", "_health"))
    @client = client
    @bucket = bucket
    @prefix = prefix
  end

  def check_all
    PARTITIONS.each_with_object({}) do |partition, results|
      results[partition] = probe(partition).to_h
    end
  end

  def ok?(results)
    results.values.all? { |v| v == "ok" }
  end

  private

  def probe(partition)
    key = "#{partition}/#{@prefix}/#{SecureRandom.uuid}"

    @client.put_object(bucket: @bucket, key: key, body: "ok", content_type: "text/plain")
    body = @client.get_object(bucket: @bucket, key: key).body.read
    raise "read mismatch" unless body == "ok"

    Result.new(partition: partition, ok: true, error: nil)
  rescue StandardError => e
    Rails.logger.error("[spaces_health] #{partition} probe failed: #{e.class}: #{e.message}")
    Result.new(partition: partition, ok: false, error: e.class.name)
  ensure
    @client.delete_object(bucket: @bucket, key: key) rescue nil
  end
end
