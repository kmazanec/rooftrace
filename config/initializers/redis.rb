# Fail fast at boot if REDIS_URL is missing, rather than letting Turbo broadcasts
# (the entire live job-status UX) drop silently while /health stays green.
# cable.yml falls back to localhost:6379 when REDIS_URL is absent, which means
# ActionCable connects "successfully" in production but to a non-existent Redis —
# every Turbo::StreamsChannel broadcast is a silent no-op. Raise in production so
# a bad deploy dies on boot with a clear message instead of degrading invisibly.
Rails.application.config.after_initialize do
  next if Rails.env.test?
  # Skip during assets:precompile build-time boot (secrets not yet injected).
  next if ENV["SECRET_KEY_BASE_DUMMY"].present?
  next if ENV["REDIS_URL"].to_s.strip.present?

  message = "[redis] REDIS_URL unset — ActionCable Turbo broadcasts will fail silently (cable.yml falls back to localhost:6379)."
  Rails.env.production? ? raise(message) : Rails.logger&.warn(message)
end
