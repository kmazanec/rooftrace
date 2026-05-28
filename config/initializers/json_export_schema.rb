# Fail fast at boot if the public JSON export contract
# (shared/json_export.schema.json, ADR-015) is missing or malformed, rather than
# surfacing a 500 on the first export request. Skipped during asset precompile /
# db tasks where the app env loads without needing the schema.
Rails.application.config.after_initialize do
  JsonExportSchema.load! unless Rails.env.test? && ENV["SKIP_JSON_EXPORT_SCHEMA_BOOT_CHECK"] == "1"
rescue JsonExportSchema::LoadError => e
  raise e unless Rails.env.test?

  Rails.logger&.warn("[json_export_schema] #{e.message}")
end
