# Surface a misconfigured dev login at boot instead of letting every login fail
# silently while /health stays green (ADR-016: the gate is two env vars,
# DEMO_USERNAME + DEMO_PASSWORD_DIGEST). In production a blank var is fatal — the
# submit surface would be unusable; in development we only warn so local work
# without the demo creds isn't blocked.
Rails.application.config.after_initialize do
  next if Rails.env.test?
  # `assets:precompile` boots the prod env at *image-build* time, before any
  # runtime secret is injected (those arrive via env_file at container start).
  # Rails sets SECRET_KEY_BASE_DUMMY to mark that build-time boot; skip the
  # runtime-config check then, or the image build aborts. The real container
  # boot does NOT set it, so the fail-fast still fires where it matters.
  next if ENV["SECRET_KEY_BASE_DUMMY"].present?

  missing = %w[DEMO_USERNAME DEMO_PASSWORD_DIGEST].select { |k| ENV[k].to_s.strip.empty? }
  next if missing.empty?

  message = "[demo_login] #{missing.join(' and ')} unset — dev login will reject every attempt (ADR-016)."
  if Rails.env.production?
    raise message
  else
    Rails.logger&.warn(message)
  end
end
