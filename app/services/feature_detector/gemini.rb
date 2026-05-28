require "digest"
require "net/http"
require "uri"
require "json"

# Gemini Flash implementation of the FeatureDetector interface (F-09, ADR-006).
#
# Uses RubyLLM to call Gemini Flash with structured JSON output.
# Falls back to a thin Net::HTTP client when RubyLLM's API cannot express
# the required configuration (e.g. response_mime_type + responseSchema headers).
# See Implementation notes in docs/features/09-vlm-feature-detection.md.
#
# Environment variables:
#   GEMINI_API_KEY        — required in production; warned (not raised) in dev/test
#   GEMINI_MODEL          — default "gemini-2.0-flash" (can override in tests)
#   CONFIDENCE_THRESHOLD  — detections below this trigger verification (default 0.6)
#
# Thread-safety: stateless; safe for concurrent Puma/Solid Queue workers.
class FeatureDetector::Gemini
  class VlmTimeout < StandardError; end
  class VlmNonJson < StandardError; end

  GEMINI_API_BASE = "https://generativelanguage.googleapis.com/v1beta".freeze
  DEFAULT_MODEL   = "gemini-2.0-flash".freeze
  CACHE_TTL       = 30.days
  RETRY_LIMIT     = 1

  # Detection JSON schema sent to Gemini for structured output.
  DETECTION_SCHEMA = {
    type: "OBJECT",
    properties: {
      features: {
        type: "ARRAY",
        items: {
          type: "OBJECT",
          properties: {
            label:      { type: "STRING", enum: FeatureDetector::KNOWN_LABELS },
            bbox_norm:  { type: "ARRAY", items: { type: "NUMBER" }, minItems: 4, maxItems: 4 },
            confidence: { type: "NUMBER" }
          },
          required: %w[label bbox_norm confidence]
        }
      }
    },
    required: %w[features]
  }.freeze

  # Verification JSON schema.
  VERIFY_SCHEMA = {
    type: "OBJECT",
    properties: {
      confirmed:  { type: "BOOLEAN" },
      confidence: { type: "NUMBER" }
    },
    required: %w[confirmed confidence]
  }.freeze

  def initialize(
    api_key: nil,
    model: nil,
    confidence_threshold: nil,
    logger: Rails.logger
  )
    @api_key   = api_key || ENV["GEMINI_API_KEY"].to_s
    @model     = model || ENV.fetch("GEMINI_MODEL", DEFAULT_MODEL)
    @threshold = (confidence_threshold || ENV.fetch("CONFIDENCE_THRESHOLD", "0.6")).to_f
    @logger    = logger
  end

  # Detect roof features in an image tile.
  #
  # @param image_tile_url [String] publicly-accessible URL of the satellite tile
  # @param roof_polygon [Hash] GeoJSON Polygon with :coordinates key (WGS84)
  # @return [Array<Hash>] schema-validated Feature hashes, empty on total failure
  def detect(image_tile_url:, roof_polygon:)
    cache_key = build_cache_key(image_tile_url, roof_polygon)

    Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
      perform_detection(image_tile_url, roof_polygon)
    end
  end

  private

  # -----------------------------------------------------------------------
  # Detection pipeline
  # -----------------------------------------------------------------------

  def perform_detection(image_tile_url, roof_polygon)
    raw_detections = call_detect_with_retry(image_tile_url, roof_polygon)
    return [] if raw_detections.nil?

    results = []
    raw_detections.each do |raw|
      detection = FeatureDetector.validate_detection(raw, logger: @logger)
      next unless detection

      if detection["confidence"] < @threshold
        verified = verify_detection(image_tile_url, detection)
        if verified
          detection["verified"] = true
          results << detection
        else
          @logger.info("[FeatureDetector::Gemini] rejected low-conf #{detection['label']} (conf=#{detection['confidence']})")
        end
      else
        detection["verified"] = true
        results << detection
      end
    end

    results
  end

  def call_detect_with_retry(image_tile_url, roof_polygon, attempt: 0)
    call_detect(image_tile_url, roof_polygon)
  rescue VlmTimeout => e
    if attempt < RETRY_LIMIT
      @logger.warn("[FeatureDetector::Gemini] timeout on attempt #{attempt + 1}, retrying: #{e.message}")
      call_detect_with_retry(image_tile_url, roof_polygon, attempt: attempt + 1)
    else
      @logger.warn("[FeatureDetector::Gemini] timeout after #{RETRY_LIMIT + 1} attempts, returning []")
      nil
    end
  rescue VlmNonJson => e
    if attempt < RETRY_LIMIT
      @logger.warn("[FeatureDetector::Gemini] non-JSON response on attempt #{attempt + 1}, retrying with sterner prompt")
      call_detect_sterner(image_tile_url, roof_polygon)
    else
      @logger.warn("[FeatureDetector::Gemini] non-JSON after retry, returning []")
      nil
    end
  end

  def call_detect(image_tile_url, roof_polygon)
    system_prompt = load_prompt("detect_system.txt")
    user_prompt   = load_prompt("detect_user.txt") % {
      image_url: image_tile_url,
      polygon_wkt: format_polygon(roof_polygon)
    }

    response_text = gemini_generate(
      system_instruction: system_prompt,
      user_message: user_prompt,
      schema: DETECTION_SCHEMA
    )

    parse_detect_response(response_text)
  end

  def call_detect_sterner(image_tile_url, roof_polygon)
    system_prompt = load_prompt("detect_system.txt")
    user_prompt   = (load_prompt("detect_user.txt") % {
      image_url: image_tile_url,
      polygon_wkt: format_polygon(roof_polygon)
    }) + "\n\nCRITICAL: Your response MUST be valid JSON only. No markdown. No explanations. Start with { and end with }."

    response_text = gemini_generate(
      system_instruction: system_prompt,
      user_message: user_prompt,
      schema: DETECTION_SCHEMA
    )

    parse_detect_response(response_text)
  rescue VlmNonJson
    nil
  end

  def parse_detect_response(text)
    parsed = JSON.parse(text.to_s.strip)
    Array(parsed["features"]).map do |f|
      {
        label: f["label"],
        bbox_norm: f["bbox_norm"],
        confidence: f["confidence"]
      }
    end
  rescue JSON::ParserError => e
    @logger.warn("[FeatureDetector::Gemini] non-JSON from Gemini: #{text.to_s[0..200]}")
    raise VlmNonJson, e.message
  end

  # -----------------------------------------------------------------------
  # Verification pass
  # -----------------------------------------------------------------------

  def verify_detection(image_tile_url, detection)
    system_prompt = load_prompt("verify_system.txt")
    bbox = detection["bbox_norm"]
    user_prompt = load_prompt("verify_user.txt") % {
      image_url: image_tile_url,
      label: detection["label"],
      xmin: bbox[0], ymin: bbox[1], xmax: bbox[2], ymax: bbox[3]
    }

    response_text = gemini_generate(
      system_instruction: system_prompt,
      user_message: user_prompt,
      schema: VERIFY_SCHEMA
    )

    parsed = JSON.parse(response_text.to_s.strip)
    confirmed = parsed["confirmed"] == true
    @logger.info("[FeatureDetector::Gemini] verification #{detection['label']}: confirmed=#{confirmed} conf=#{parsed['confidence']}")
    confirmed
  rescue VlmTimeout, VlmNonJson, JSON::ParserError => e
    @logger.warn("[FeatureDetector::Gemini] verification failed (#{e.class}): #{e.message} — dropping detection")
    false
  end

  # -----------------------------------------------------------------------
  # Gemini HTTP client (thin Net::HTTP, bypassing RubyLLM for structured output)
  #
  # Decision: we use a thin Net::HTTP client rather than RubyLLM's chat API.
  # RubyLLM's schema support passes `responseSchema` to Gemini only for models
  # >= 2.5, and uses a proprietary GeminiSchema transformer that strips
  # additionalProperties. For gemini-2.0-flash we need the raw
  # `responseSchema` / `response_mime_type` generationConfig. A thin client
  # gives us full control with no abstraction tax; the FeatureDetector interface
  # is the real contract, not the HTTP layer.
  # -----------------------------------------------------------------------

  def gemini_generate(system_instruction:, user_message:, schema:, timeout: 30)
    raise ArgumentError, "GEMINI_API_KEY is not set" if @api_key.to_s.empty?

    url  = URI("#{GEMINI_API_BASE}/models/#{@model}:generateContent?key=#{@api_key}")
    body = build_request_body(system_instruction, user_message, schema)

    http_post(url, body, timeout: timeout)
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    raise VlmTimeout, "Gemini #{@model} timed out: #{e.message}"
  end

  def build_request_body(system_instruction, user_message, schema)
    {
      system_instruction: { parts: [{ text: system_instruction }] },
      contents: [
        { role: "user", parts: [{ text: user_message }] }
      ],
      generationConfig: {
        response_mime_type: "application/json",
        responseSchema: schema
      }
    }
  end

  def http_post(url, body, timeout: 30)
    request = Net::HTTP::Post.new(url)
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)

    response = Net::HTTP.start(
      url.host, url.port,
      use_ssl: true,
      open_timeout: timeout,
      read_timeout: timeout
    ) { |http| http.request(request) }

    case response.code.to_i
    when 200..299
      extract_text(JSON.parse(response.body))
    else
      raise VlmNonJson, "Gemini returned #{response.code}: #{response.body.to_s[0..200]}"
    end
  rescue JSON::ParserError => e
    raise VlmNonJson, "Gemini response not parseable JSON: #{e.message}"
  end

  def extract_text(data)
    data.dig("candidates", 0, "content", "parts", 0, "text") || ""
  end

  # -----------------------------------------------------------------------
  # Helpers
  # -----------------------------------------------------------------------

  def build_cache_key(image_tile_url, roof_polygon)
    image_hash   = Digest::SHA256.hexdigest(image_tile_url.to_s)[0..15]
    polygon_hash = Digest::SHA256.hexdigest(roof_polygon.to_json)[0..15]
    "feature_detector/v1/#{image_hash}/#{polygon_hash}"
  end

  def format_polygon(roof_polygon)
    coords = roof_polygon.dig("coordinates", 0) ||
             roof_polygon.dig(:coordinates, 0) ||
             []
    coords.map { |lon, lat| "[#{lon}, #{lat}]" }.join(", ")
  end

  def load_prompt(filename)
    path = Rails.root.join("app", "services", "feature_detector", "prompts", filename)
    File.read(path)
  end
end
