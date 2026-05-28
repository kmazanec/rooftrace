# Abstract boundary for VLM-based roof feature detection (F-09, ADR-006).
#
# Implementations:
#   FeatureDetector::Gemini  — default; uses RubyLLM to call Gemini Flash
#
# Vendor-swap guarantee: adding FeatureDetector::OpenAI requires only a new
# file in app/services/feature_detector/; nothing outside changes.
#
# Factory:
#   FeatureDetector.build   → implementation selected by FEATURE_DETECTOR env
#                             (default "gemini")
module FeatureDetector
  KNOWN_LABELS = %w[chimney vent skylight dormer satellite_dish].freeze
  DETECTOR_NAME = "gemini-flash-2.0".freeze
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
  # @return [FeatureDetector::Gemini, ...]
  def self.build
    backend = ENV.fetch("FEATURE_DETECTOR", "gemini").downcase
    case backend
    when "gemini"
      FeatureDetector::Gemini.new
    else
      raise ArgumentError, "Unknown FEATURE_DETECTOR: #{backend.inspect}"
    end
  end
end
