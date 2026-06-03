# Fail fast at boot if SIDECAR_SHARED_SECRET is missing, rather than letting
# every sidecar call fail at request time while /health stays green. SIDECAR_URL
# has a sensible default ("http://127.0.0.1:3011") so it is not required here —
# SidecarClient raises at construction if the URL is unreachable, but the config
# itself is optional. In production a blank secret is fatal because the sidecar
# rejects every unauthenticated request with 401 (ADR-008). In dev/test we only
# warn so local work without the var set isn't blocked.
Rails.application.config.after_initialize do
  next if Rails.env.test?
  # Skip during assets:precompile build-time boot (secrets not yet injected).
  next if ENV["SECRET_KEY_BASE_DUMMY"].present?

  next if ENV["SIDECAR_SHARED_SECRET"].to_s.strip.present?

  message = "[sidecar] SIDECAR_SHARED_SECRET unset — every sidecar call will be " \
            "rejected with 401 (ADR-008)."
  if Rails.env.production?
    raise message
  else
    Rails.logger&.warn(message)
  end
end
