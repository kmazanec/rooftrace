require "json"
require "json_schemer"

# Rails-side loader/validator for the PUBLIC JSON export contract
# (`shared/json_export.schema.json`, ADR-015). This is the integration contract
# downstream consumers (insurance, estimating tools) script against; it is
# INDEPENDENT of the internal pipeline schema (its own `schema_version`, locked
# at 1.0.0 via a `const`).
#
# Mirrors the proven `PipelineSchema` pattern: the schema document and the
# compiled root validator are memoized behind a mutex (so Puma's threaded
# requests can't race), and `load!` (called from a boot initializer) eagerly
# parses the file so a missing/malformed schema fails at boot with a clear
# message, not as a 500 on the first export request.
#
# Unlike PipelineSchema (which validates named `$defs` entities), the export
# schema is a single top-level document, so this validates the whole payload
# against the root.
module JsonExportSchema
  SCHEMA_PATH = Rails.root.join("shared", "json_export.schema.json").freeze
  META_SCHEMA = "https://json-schema.org/draft/2020-12/schema".freeze

  class LoadError < StandardError; end

  @mutex = Mutex.new

  class << self
    # Eagerly parse the schema and confirm it's usable. Safe to call at boot.
    def load!
      document
      validator
      true
    end

    # The parsed schema document.
    def document
      @mutex.synchronize { @document ||= parse_document }
    end

    # The locked export contract version, read from the schema's `const` so the
    # serializer and specs never hard-code a literal that could drift from the
    # contract file.
    def version
      document.dig("properties", "schema_version", "const")
    end

    # A JSONSchemer instance rooted at the whole export document.
    def validator
      # Resolve `document` OUTSIDE the mutex: it takes the same (non-reentrant)
      # lock, so reading it inside this block would deadlock on a cold cache.
      doc = document
      @mutex.synchronize do
        @validator ||= JSONSchemer.schema(doc, meta_schema: META_SCHEMA)
      end
    end

    # true/false: does `payload` satisfy the export contract?
    def valid?(payload)
      validator.valid?(payload)
    end

    # Array of human-readable validation error strings (empty when valid).
    def errors_for(payload)
      validator.validate(payload).map do |err|
        pointer = err["data_pointer"].to_s.empty? ? "(root)" : err["data_pointer"]
        "#{pointer}: #{err['type']}"
      end
    end

    private

    def parse_document
      JSON.parse(File.read(SCHEMA_PATH))
    rescue Errno::ENOENT
      raise LoadError, "json export schema not found at #{SCHEMA_PATH}"
    rescue JSON::ParserError => e
      raise LoadError, "json export schema at #{SCHEMA_PATH} is not valid JSON: #{e.message}"
    end
  end
end
