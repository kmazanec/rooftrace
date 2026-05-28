# Boot-time check for VLM feature detection configuration (ADR-006).
# Mirrors the "fail-fast in production, warn in dev/test" pattern from demo_login.rb.
#
# OPENROUTER_API_KEY is required for any real VLM call (the detector reaches
# every candidate model through OpenRouter — ADR-006). CI runs all tests with
# WebMock stubs so no key is needed; production must have it set.
Rails.application.config.after_initialize do
  next if Rails.env.test?
  # Skip the runtime-config check during `assets:precompile` (image-build boot,
  # before secrets are injected) — Rails marks it with SECRET_KEY_BASE_DUMMY.
  # The real container boot doesn't set it, so the fail-fast still fires there.
  next if ENV["SECRET_KEY_BASE_DUMMY"].present?

  missing = %w[OPENROUTER_API_KEY].select { |k| ENV[k].to_s.strip.empty? }
  next if missing.empty?

  message = "[feature_detector] #{missing.join(', ')} unset — VLM calls will raise at runtime."
  if Rails.env.production?
    raise message
  else
    Rails.logger&.warn(message)
  end
end
