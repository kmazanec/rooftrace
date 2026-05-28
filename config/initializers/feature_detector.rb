# Boot-time check for F-09 VLM feature detection configuration.
# Mirrors the "fail-fast in production, warn in dev/test" pattern from demo_login.rb.
#
# GEMINI_API_KEY is required for any real VLM call. CI runs all tests with
# WebMock stubs so no key is needed; production must have it set.
Rails.application.config.after_initialize do
  next if Rails.env.test?
  # Skip the runtime-config check during `assets:precompile` (image-build boot,
  # before secrets are injected) — Rails marks it with SECRET_KEY_BASE_DUMMY.
  # The real container boot doesn't set it, so the fail-fast still fires there.
  next if ENV["SECRET_KEY_BASE_DUMMY"].present?

  missing = %w[GEMINI_API_KEY].select { |k| ENV[k].to_s.strip.empty? }
  next if missing.empty?

  message = "[feature_detector] #{missing.join(', ')} unset — VLM calls will raise at runtime (F-09)."
  if Rails.env.production?
    raise message
  else
    Rails.logger&.warn(message)
  end
end
