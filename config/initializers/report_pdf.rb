# Boot-time check for the roof-report PDF pipeline (ADR-014). Mirrors the
# "fail-fast in production, warn in dev/test" pattern used by demo_login.rb and
# feature_detector.rb.
#
# MAPBOX_PRIVATE_TOKEN is required for the Mapbox Static Images fallback that
# renders the roof diagram when the sidecar's headless map renderer is
# unavailable. Without it, a sidecar render failure would leave the report with
# no roof diagram. CI runs all tests with stubs/WebMock so no token is needed;
# production must have it set so the degraded path still produces a diagram.
# (This is the SERVER-SIDE token — the same one the sidecar imagery/render uses;
# distinct from MAPBOX_PUBLIC_TOKEN, which is the browser viewer basemap only.)
Rails.application.config.after_initialize do
  next if Rails.env.test?
  # Skip during `assets:precompile` (image-build boot, before secrets exist) —
  # Rails marks it with SECRET_KEY_BASE_DUMMY.
  next if ENV["SECRET_KEY_BASE_DUMMY"].present?

  missing = %w[MAPBOX_PRIVATE_TOKEN].select { |k| ENV[k].to_s.strip.empty? }
  next if missing.empty?

  message = "[report_pdf] #{missing.join(', ')} unset — the Mapbox Static map fallback will raise at runtime."
  if Rails.env.production?
    raise message
  else
    Rails.logger&.warn(message)
  end
end
