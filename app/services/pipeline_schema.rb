require "json"
require "json_schemer"

# Rails-side view of the cross-language pipeline contract
# (`shared/pipeline_schema.json`, ADR-008). Loads the JSON Schema once and
# validates payloads against a named `$def` (e.g. "PipelineRequest").
#
# The Python sidecar mirrors this with Pydantic models in
# `sidecar/contracts/pipeline.py`; both sides validate the same fixture corpus
# in `spec/fixtures/pipeline/` so the two views can't silently diverge.
#
# Thread-safety: the schema document and per-entity compiled validators are
# memoized behind a mutex, so concurrent requests on Puma's threaded server
# can't race to build or overwrite a cached validator. `load!` (called from a
# boot initializer) eagerly parses the file so a missing/malformed schema fails
# at boot with a clear message, not as a 500 on the first request.
module PipelineSchema
  SCHEMA_PATH = Rails.root.join("shared", "pipeline_schema.json").freeze
  META_SCHEMA = "https://json-schema.org/draft/2020-12/schema".freeze

  class UnknownEntity < StandardError; end
  class LoadError < StandardError; end

  @mutex = Mutex.new

  class << self
    # Eagerly parse the schema and confirm it's usable. Safe to call at boot.
    def load!
      document
      true
    end

    # The parsed schema document (the whole file, including `$defs`).
    def document
      @mutex.synchronize { @document ||= parse_document }
    end

    def version
      document.fetch("pipelineSchemaVersion")
    end

    # A JSONSchemer instance rooted at a named entity in `$defs`, with the
    # full document supplied as the base so internal `$ref`s resolve.
    def validator_for(entity)
      defs = document.fetch("$defs")
      raise UnknownEntity, "no such entity: #{entity}" unless defs.key?(entity)

      @mutex.synchronize do
        (@validators ||= {})[entity] ||= JSONSchemer.schema(
          { "$ref" => "#/$defs/#{entity}", "$defs" => defs },
          meta_schema: META_SCHEMA
        )
      end
    end

    # true/false: does `payload` satisfy the named entity shape?
    def valid?(entity, payload)
      validator_for(entity).valid?(payload)
    end

    # Array of human-readable validation error strings (empty when valid).
    def errors_for(entity, payload)
      validator_for(entity).validate(payload).map do |err|
        pointer = err["data_pointer"].to_s.empty? ? "(root)" : err["data_pointer"]
        "#{pointer}: #{err['type']}"
      end
    end

    private

    def parse_document
      JSON.parse(File.read(SCHEMA_PATH))
    rescue Errno::ENOENT
      raise LoadError, "pipeline schema not found at #{SCHEMA_PATH}"
    rescue JSON::ParserError => e
      raise LoadError, "pipeline schema at #{SCHEMA_PATH} is not valid JSON: #{e.message}"
    end
  end
end
