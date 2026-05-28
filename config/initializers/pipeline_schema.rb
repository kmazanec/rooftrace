# Fail fast at boot if the pipeline contract (shared/pipeline_schema.json) is
# missing or malformed, rather than surfacing a 500 on the first request that
# validates a payload. Skipped during asset precompile / db tasks where the app
# env loads without needing the schema.
Rails.application.config.after_initialize do
  PipelineSchema.load! unless Rails.env.test? && ENV["SKIP_PIPELINE_SCHEMA_BOOT_CHECK"] == "1"
rescue PipelineSchema::LoadError => e
  raise e unless Rails.env.test?

  Rails.logger&.warn("[pipeline_schema] #{e.message}")
end
