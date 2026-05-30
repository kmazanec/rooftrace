# Fail fast at boot if the DigitalOcean Spaces credentials are missing in
# production. Active Storage (config/storage.yml :spaces service) and every
# internal S3 client (SpacesUploader, ArtifactStore, SpacesHealth, etc.) all
# require STORAGE_ACCESS_KEY and STORAGE_SECRET_KEY — a blank key boots green
# then 500s every upload or artifact read. STORAGE_ENDPOINT is also required;
# STORAGE_BUCKET and STORAGE_REGION both have defaults so they are not checked.
# In dev/test we only warn so local work and the suite are not blocked.
Rails.application.config.after_initialize do
  next if Rails.env.test?
  # Skip during assets:precompile build-time boot (secrets not yet injected).
  next if ENV["SECRET_KEY_BASE_DUMMY"].present?

  missing = %w[STORAGE_ACCESS_KEY STORAGE_SECRET_KEY STORAGE_ENDPOINT].select do |k|
    ENV[k].to_s.strip.empty?
  end
  next if missing.empty?

  message = "[storage] #{missing.join(' and ')} unset — Active Storage uploads " \
            "and Spaces reads will fail (ADR-010)."
  if Rails.env.production?
    raise message
  else
    Rails.logger&.warn(message)
  end
end
