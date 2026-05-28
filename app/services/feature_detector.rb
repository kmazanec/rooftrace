# Abstract boundary for VLM-based roof feature detection (ADR-006).
#
# Implementations:
#   FeatureDetector::OpenRouter  — default; calls a VLM through OpenRouter's
#     OpenAI-compatible API so any candidate model (Gemini, GPT-4o, Claude,
#     Qwen-VL) is reachable by changing one model slug. The production model
#     is chosen by the accuracy evaluation (ADR-006 / ADR-017), not assumed.
#
# Vendor-swap guarantee: adding another backend requires only a new file in
# app/services/feature_detector/ plus a case in .build; nothing outside changes.
#
# Factory:
#   FeatureDetector.build   → implementation selected by FEATURE_DETECTOR env
#                             (default "openrouter")
module FeatureDetector
  KNOWN_LABELS = %w[chimney vent skylight dormer satellite_dish].freeze
  # Provenance string surfaced in detection output (which model produced these).
  # Tracks the default model slug; the eval may change which model is default.
  DETECTOR_NAME = "openrouter:google/gemini-2.5-flash".freeze
  PIPELINE_SCHEMA_VERSION = PipelineSchema.version

  # Called by concrete implementations to filter + schema-validate a raw
  # detection hash coming from the VLM. Returns nil (and logs) when the
  # detection fails any check.
  #
  # @param raw [Hash] Detection produced by the VLM parser; symbolize_keys
  #   must have been called.
  # @param logger [Logger]
  # @return [Hash, nil]
  def self.validate_detection(raw, logger: Rails.logger)
    label = raw[:label].to_s
    unless KNOWN_LABELS.include?(label)
      logger.warn("[FeatureDetector] discarding out-of-vocab label: #{label.inspect}")
      return nil
    end

    canonical = {
      "label" => label,
      "bbox_norm" => Array(raw[:bbox_norm]).map(&:to_f),
      "verified" => raw[:verified] == true,
      "source" => "imagery",
      "confidence" => raw[:confidence].to_f
    }

    errors = PipelineSchema.errors_for("Feature", canonical)
    if errors.any?
      logger.warn("[FeatureDetector] detection schema errors: #{errors.join('; ')}")
      return nil
    end

    canonical
  end

  # Build the right implementation from FEATURE_DETECTOR env.
  # @return [FeatureDetector::OpenRouter, ...]
  def self.build
    backend = ENV.fetch("FEATURE_DETECTOR", "openrouter").downcase
    case backend
    when "openrouter"
      FeatureDetector::OpenRouter.new
    else
      raise ArgumentError, "Unknown FEATURE_DETECTOR: #{backend.inspect}"
    end
  end
end
