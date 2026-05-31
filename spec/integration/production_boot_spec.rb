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
    let(:storage_config) do
      raw = ERB.new(File.read(Rails.root.join("config/storage.yml"))).result
      YAML.safe_load(raw, aliases: true).deep_symbolize_keys
    end

    it "is defined" do
      expect(storage_config).to include(:spaces)
    end

    it "instantiates without raising (its options must be valid Aws::S3::Client options)" do
      expect {
        ActiveStorage::Service.configure(:spaces, storage_config)
      }.not_to raise_error
    end
  end
end
