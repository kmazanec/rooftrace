require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Rooftrace
  class Application < Rails::Application
    config.load_defaults 8.1

    config.autoload_lib(ignore: %w[assets tasks])

    # Ignore sibling non-Rails components (sidecar, ios, ops, etc.) — they are
    # not part of the Rails app even though they live in the same repo.
    Rails.autoloaders.main.ignore(
      Rails.root.join("sidecar"),
      Rails.root.join("ios"),
      Rails.root.join("ops"),
      Rails.root.join("shared"),
      Rails.root.join("docs")
    )

    # Default new models / migrations to uuid primary keys + foreign keys
    # (matches the convention established for SkeletonPing and that future
    # geometry tables will rely on).
    config.generators do |g|
      g.orm :active_record, primary_key_type: :uuid
      g.test_framework :rspec, fixture: false
      g.factory_bot suffix: "factory"
    end

    # Geographic/UTC time everywhere; the geospatial pipeline assumes UTC.
    config.time_zone = "UTC"

    # PostGIS ships internal tables (spatial_ref_sys, tiger.*, topology.*) that
    # the Ruby schema dumper can't represent (geometry columns aren't in pg's
    # default OID map). Use raw SQL structure dumps instead — necessary for any
    # Postgres+PostGIS project on Rails.
    config.active_record.schema_format = :sql
  end
end
