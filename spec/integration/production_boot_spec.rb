require "rails_helper"
require "yaml"
require "erb"

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
end
