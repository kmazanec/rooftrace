source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.3"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Bundle the React report-viewer island with esbuild (ADR-013). importmap-rails
# above stays the loader for the Hotwire/Stimulus pages; jsbundling only builds
# the standalone viewer bundle under app/javascript/viewer.
gem "jsbundling-rails"
# Use Tailwind CSS [https://github.com/rails/tailwindcss-rails]
gem "tailwindcss-rails"

# Dev-login password digest verification (ADR-016: bcrypt-digested DEMO_PASSWORD).
gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 1.2"

# S3-compatible client (DigitalOcean Spaces per ADR-010).
gem "aws-sdk-s3", "~> 1.180", require: false

# JSON Schema draft 2020-12 validation for the Rails<->sidecar pipeline contract
# (shared/pipeline_schema.json). The `json-schema` gem does not support
# draft 2020-12; `json_schemer` does.
gem "json_schemer", "~> 2.3"

# VLM feature detection via Gemini Flash (ADR-006).
gem "ruby_llm", "~> 1.2"

# HTML-to-PDF for the roof measurement report (ADR-014). Grover drives a
# headless Chromium via Puppeteer to print a print-layout ERB to PDF bytes.
gem "grover", "~> 1.2"

group :development, :test do
  # RSpec for testing (request specs, model specs, etc.)
  gem "rspec-rails", "~> 7.1"
  gem "factory_bot_rails"
  # Load .env files in dev/test for local Spaces/sidecar credentials.
  gem "dotenv-rails"

  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"
  # Hit the real running sidecar from request specs (no mocks, by design).
  gem "webmock", require: false
  # Parse generated PDFs in the system test to assert text fragments + that a
  # map image object is embedded.
  gem "pdf-reader", require: false
end
