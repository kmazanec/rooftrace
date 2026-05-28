# Surface a misconfigured dev login at boot instead of letting every login fail
# silently while /health stays green (ADR-016: the gate is two env vars,
# DEMO_USERNAME + DEMO_PASSWORD_DIGEST). In production a blank var is fatal — the
# submit surface would be unusable; in development we only warn so local work
# without the demo creds isn't blocked.
Rails.application.config.after_initialize do
  next if Rails.env.test?

  missing = %w[DEMO_USERNAME DEMO_PASSWORD_DIGEST].select { |k| ENV[k].to_s.strip.empty? }
  next if missing.empty?

  message = "[demo_login] #{missing.join(' and ')} unset — dev login will reject every attempt (ADR-016)."
  if Rails.env.production?
    raise message
  else
    Rails.logger&.warn(message)
  end
end
