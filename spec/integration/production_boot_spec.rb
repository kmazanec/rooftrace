require "rails_helper"
require "yaml"
require "erb"
require "shellwords"

# Guards the class of failure that sails through the rest of the suite: config
# that is only instantiated in PRODUCTION. The suite runs under RAILS_ENV=test,
# where active_storage.service is :test (Disk), so the :spaces S3 service is never
# built — and a bad option in config/storage.yml (e.g. an invalid `prefix:` key,
# which Aws::S3::Client.new rejects) crashes prod boot while CI stays green.
#
# This instantiates the production-only :spaces service directly, exercising the
# exact path that raised `invalid configuration option :prefix` at deploy time, so
# the suite fails BEFORE a deploy rather than at the health-check.
RSpec.describe "production boot", type: :model do
  describe "the :spaces Active Storage service (config/storage.yml)" do
    # The real storage.yml options, but with credentials and endpoint stubbed so
    # building the S3 service validates the OPTION NAMES (where :prefix raises an
    # ArgumentError, before any credential work) without resolving real AWS
    # credentials — in CI there are no STORAGE_* env vars, so the SDK would
    # otherwise fall back to the EC2 instance-metadata endpoint, which WebMock
    # blocks. Invalid-option validation happens regardless of credentials.
    let(:storage_config) do
      raw = ERB.new(File.read(Rails.root.join("config/storage.yml"))).result
      parsed = YAML.safe_load(raw, aliases: true).deep_symbolize_keys
      parsed[:spaces] = parsed.fetch(:spaces, {}).merge(
        access_key_id: "test-access-key",
        secret_access_key: "test-secret-key",
        endpoint: "https://example.invalid"
      )
      parsed
    end

    it "is defined" do
      raw = ERB.new(File.read(Rails.root.join("config/storage.yml"))).result
      expect(YAML.safe_load(raw, aliases: true)).to include("spaces")
    end

    it "instantiates without raising (its options must be valid Aws::S3::Client options)" do
      expect {
        ActiveStorage::Service.configure(:spaces, storage_config)
      }.not_to raise_error
    end
  end

  # The Solid stack (cache/queue/cable) lives in DEDICATED Postgres pools
  # (CACHE_/QUEUE_/CABLE_DATABASE_URL → config/database.yml). production.rb must
  # point each store at its pool via `connects_to`; if it doesn't, the store falls
  # back to the PRIMARY connection where solid_cache_entries / solid_queue_jobs
  # don't exist — every cache/queue touch 500s with PG::UndefinedTable (this is
  # what broke /health's spaces_check on a healthy deploy). The suite runs in test
  # (cache_store :null_store, cable :test), so this is only visible by reading the
  # PRODUCTION config — done here in a subprocess so the test env is untouched.
  describe "the Solid stack connects_to (config/environments/production.rb)" do
    it "points solid_cache and solid_queue at their own pools, not the primary" do
      script = <<~RUBY
        c = Rails.application.config
        cache = c.solid_cache.connects_to.to_s
        queue = c.solid_queue.connects_to.to_s
        abort("solid_cache not on :cache pool -> \#{cache.inspect}") unless cache.include?("cache")
        abort("solid_queue not on :queue pool -> \#{queue.inspect}") unless queue.include?("queue")
        puts "SOLID_CONNECTS_OK"
      RUBY
      # eager_load=false: we only need the config object, not a full boot (which
      # would trip prod boot-checks for absent secrets). SECRET_KEY_BASE_DUMMY makes
      # the secret-requiring initializers skip, matching the assets:precompile path.
      out = `RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 SECRET_KEY_BASE=dummy \
             bin/rails runner #{Shellwords.escape(script)} 2>&1`
      expect(out).to include("SOLID_CONNECTS_OK"), "production Solid config check failed:\n#{out}"
    end
  end
end
