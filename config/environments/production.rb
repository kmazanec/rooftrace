require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on DigitalOcean Spaces (S3-compatible; see config/storage.yml).
  # The :spaces service maps to the single STORAGE_BUCKET partitioned by key prefix (ADR-010).
  config.active_storage.service = :spaces

  # Caddy terminates TLS and forwards plain HTTP to Rails on the internal Docker network.
  # assume_ssl tells Rails to treat every inbound request as HTTPS so it issues
  # Secure cookies and HSTS headers even though the socket itself is plain HTTP.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for /up so the internal-network container
  # healthcheck (plain HTTP from Caddy's health probe) is not redirected to HTTPS.
  # assume_ssl=true above ensures real user-facing requests still get Secure
  # cookies and HSTS — this exclusion is belt-and-suspenders for the probe only.
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Durable cache + queue backed by Postgres (the Solid stack), NOT the default
  # in-process stores. Both live in their own DB pools on the one postgis
  # container (CACHE_/QUEUE_DATABASE_URL → the `cache`/`queue` pools in
  # config/database.yml). Without these, Active Job defaults to the :async
  # adapter — jobs run inside Puma and are LOST on every deploy/restart, which
  # for the geometry/fusion/projection pipeline means silently dropped work.
  config.cache_store = :solid_cache_store
  # Point Solid Cache at the `cache` pool (CACHE_DATABASE_URL); without this it
  # uses the PRIMARY connection, where solid_cache_entries does not exist, and
  # every cache read/write — including HealthController#spaces_check — 500s with
  # PG::UndefinedTable. Mirrors solid_queue.connects_to below.
  config.solid_cache.connects_to = { database: { writing: :cache, reading: :cache } }

  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Set host to be used by links generated in mailer templates.
  # APP_HOST defaults to the known production hostname; override via env for
  # staging or when the domain changes.
  config.action_mailer.default_url_options = {
    host: ENV.fetch("APP_HOST", "rooftrace.biograph.dev"),
    protocol: "https"
  }

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via bin/rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # DNS-rebinding protection: only accept requests whose Host header matches the
  # production hostname (or APP_HOST override). /up is excluded so the internal
  # Caddy healthcheck (which uses the container name, not the public hostname)
  # stays reachable without disabling protection globally.
  config.hosts = [ ENV.fetch("APP_HOST", "rooftrace.biograph.dev") ]
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
