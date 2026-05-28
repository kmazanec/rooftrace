require "json"
require "json_schemer"

# Rails-side view of the cross-language pipeline contract
# (`shared/pipeline_schema.json`, ADR-008). Loads the JSON Schema once and
# validates payloads against a named `$def` (e.g. "PipelineRequest").
#
# The Python sidecar mirrors this with Pydantic models in
# `sidecar/contracts/pipeline.py`; both sides validate the same fixture corpus
# in `spec/fixtures/pipeline/` so the two views can't silently diverge.
module PipelineSchema
  SCHEMA_PATH = Rails.root.join("shared", "pipeline_schema.json").freeze

  class UnknownEntity < StandardError; end

  class << self
    # The parsed schema document (the whole file, including `$defs`).
    def document
      @document ||= JSON.parse(File.read(SCHEMA_PATH))
    end

    def version
      document.fetch("pipelineSchemaVersion")
    end

    # A JSONSchemer instance rooted at a named entity in `$defs`, with the
    # full document supplied as the base so internal `$ref`s resolve.
    def validator_for(entity)
      raise UnknownEntity, "no such entity: #{entity}" unless document.fetch("$defs").key?(entity)

      validators[entity] ||= JSONSchemer.schema(
        { "$ref" => "#/$defs/#{entity}" }.merge("$defs" => document.fetch("$defs")),
        meta_schema: "https://json-schema.org/draft/2020-12/schema"
      )
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

    def validators
      @validators ||= {}
    end
  end
end
