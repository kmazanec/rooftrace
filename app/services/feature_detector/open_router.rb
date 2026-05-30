require "digest"
require "net/http"
require "uri"
require "json"

# OpenRouter implementation of the FeatureDetector interface (ADR-006).
#
# Calls a VLM through OpenRouter's OpenAI-compatible Chat Completions API with
# structured JSON output. Routing through OpenRouter (rather than a provider's
# native API) is deliberate: every candidate model — Gemini, GPT-4o, Claude,
# Qwen-VL — is reachable behind one client by changing the `model` slug, which
# is what makes the model evaluation (ADR-006 / ADR-017) a one-string swap
# instead of a new client per provider. The production model is chosen by that
# evaluation; the default here is just the v1 starting model.
#
# Environment variables:
#   OPENROUTER_API_KEY    — required in production; warned (not raised) in dev/test
#   OPENROUTER_MODEL      — model slug, default "google/gemini-2.5-flash"
#   CONFIDENCE_THRESHOLD  — detections below this trigger verification (default 0.6)
#
# Thread-safety: stateless; safe for concurrent Puma/Solid Queue workers.
class FeatureDetector::OpenRouter
  class VlmTimeout < StandardError; end
  class VlmNonJson < StandardError; end
  # Raised on a 5xx (provider overload) or 429 (rate limit) HTTP response.
  # Distinct from VlmNonJson (a 2xx body that isn't the expected JSON): a sterner
  # formatting prompt can't fix server overload / rate limiting, so the retry path
  # re-sends the SAME prompt once rather than reformatting.
  class VlmServerError < StandardError; end

  API_URL       = "https://openrouter.ai/api/v1/chat/completions".freeze
  DEFAULT_MODEL = "google/gemini-2.5-flash".freeze
  CACHE_TTL     = 30.days
  RETRY_LIMIT   = 1

  # Image tiles live in DigitalOcean Spaces; the model fetches the URL
  # server-side, so we allowlist the host(s) it may point at (SSRF defense).
  # Comma-separated override via IMAGE_TILE_HOST_ALLOWLIST; defaults to the
  # Spaces CDN domains.
  DEFAULT_TILE_HOST_SUFFIXES = %w[.digitaloceanspaces.com .cdn.digitaloceanspaces.com].freeze

  # Detection JSON schema sent to the model for structured output.
  DETECTION_SCHEMA = {
    type: "object",
    properties: {
      features: {
        type: "array",
        items: {
          type: "object",
          properties: {
            label:      { type: "string", enum: FeatureDetector::KNOWN_LABELS },
            bbox_norm:  { type: "array", items: { type: "number" }, minItems: 4, maxItems: 4 },
            confidence: { type: "number" }
          },
          required: %w[label bbox_norm confidence],
          additionalProperties: false
        }
      }
    },
    required: %w[features],
    additionalProperties: false
  }.freeze

  # Verification JSON schema.
  VERIFY_SCHEMA = {
    type: "object",
    properties: {
      confirmed:  { type: "boolean" },
      confidence: { type: "number" }
    },
    required: %w[confirmed confidence],
    additionalProperties: false
  }.freeze

  def initialize(
    api_key: nil,
    model: nil,
    confidence_threshold: nil,
    logger: Rails.logger
  )
    @api_key   = api_key || ENV["OPENROUTER_API_KEY"].to_s
    @model     = model || ENV.fetch("OPENROUTER_MODEL", DEFAULT_MODEL)
    @threshold = (confidence_threshold || ENV.fetch("CONFIDENCE_THRESHOLD", "0.6")).to_f
    @logger    = logger
  end

  # The model slug this instance actually calls (env-overridden, not the default).
  attr_reader :model

  # Provenance identity for THIS instance — reflects the actual model in use, so
  # an eval-suite override is recorded accurately (vs. the static module default).
  def detector_name
    "openrouter:#{@model}"
  end

  # Detect roof features in an image tile.
  #
  # @param image_tile_url [String] publicly-accessible URL of the satellite tile
  # @param roof_polygon [Hash] GeoJSON Polygon with :coordinates key (WGS84)
  # @return [Array<Hash>] schema-validated Feature hashes, empty on total failure
  def detect(image_tile_url:, roof_polygon:)
    # The model fetches this URL server-side, so it's an SSRF surface: an
    # attacker URL like http://169.254.169.254/ (cloud metadata) or a loopback
    # host would be fetched by the provider's infra on our behalf. And it's
    # interpolated into the prompt, so control chars could smuggle injected
    # instructions. Validate both before use (the output allowlist is a further
    # line of defense).
    validate_image_url!(image_tile_url)

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
          @logger.info("[FeatureDetector::OpenRouter] rejected low-conf #{detection['label']} (conf=#{detection['confidence']})")
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
      @logger.warn("[FeatureDetector::OpenRouter] timeout on attempt #{attempt + 1}, retrying: #{e.message}")
      call_detect_with_retry(image_tile_url, roof_polygon, attempt: attempt + 1)
    else
      @logger.warn("[FeatureDetector::OpenRouter] timeout after #{RETRY_LIMIT + 1} attempts, returning []")
      nil
    end
  rescue VlmServerError => e
    if attempt < RETRY_LIMIT
      # 5xx / 429: a sterner formatting prompt can't help — re-send the SAME
      # prompt once (the provider may have shed load / the rate window passed).
      @logger.warn("[FeatureDetector::OpenRouter] server error on attempt #{attempt + 1}, retrying with same prompt: #{e.message}")
      call_detect_with_retry(image_tile_url, roof_polygon, attempt: attempt + 1)
    else
      @logger.warn("[FeatureDetector::OpenRouter] server error after #{RETRY_LIMIT + 1} attempts, returning []")
      nil
    end
  rescue VlmNonJson => e
    if attempt < RETRY_LIMIT
      @logger.warn("[FeatureDetector::OpenRouter] non-JSON response on attempt #{attempt + 1}, retrying with sterner prompt")
      begin
        call_detect_sterner(image_tile_url, roof_polygon)
      rescue VlmTimeout => te
        # The sterner retry itself can time out; swallow to the documented []
        # rather than letting it escape detect.
        @logger.warn("[FeatureDetector::OpenRouter] sterner-prompt retry timed out, returning []: #{te.message}")
        nil
      end
    else
      @logger.warn("[FeatureDetector::OpenRouter] non-JSON after retry, returning []")
      nil
    end
  end

  def call_detect(image_tile_url, roof_polygon)
    system_prompt = load_prompt("detect_system.txt")
    user_prompt   = load_prompt("detect_user.txt") % {
      image_url: image_tile_url,
      polygon_wkt: format_polygon(roof_polygon)
    }

    response_text = generate(
      system_instruction: system_prompt,
      user_message: user_prompt,
      image_url: image_tile_url,
      schema_name: "roof_features",
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

    response_text = generate(
      system_instruction: system_prompt,
      user_message: user_prompt,
      image_url: image_tile_url,
      schema_name: "roof_features",
      schema: DETECTION_SCHEMA
    )

    parse_detect_response(response_text)
  rescue VlmNonJson, VlmServerError
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
    @logger.warn("[FeatureDetector::OpenRouter] non-JSON from model: #{text.to_s[0..200]}")
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

    response_text = generate(
      system_instruction: system_prompt,
      user_message: user_prompt,
      image_url: image_tile_url,
      schema_name: "roof_feature_verification",
      schema: VERIFY_SCHEMA
    )

    parsed = JSON.parse(response_text.to_s.strip)
    confirmed = parsed["confirmed"] == true
    @logger.info("[FeatureDetector::OpenRouter] verification #{detection['label']}: confirmed=#{confirmed} conf=#{parsed['confidence']}")
    confirmed
  rescue VlmTimeout, VlmNonJson, JSON::ParserError => e
    @logger.warn("[FeatureDetector::OpenRouter] verification failed (#{e.class}): #{e.message} — dropping detection")
    false
  end

  # -----------------------------------------------------------------------
  # OpenRouter HTTP client (thin Net::HTTP, OpenAI-compatible Chat Completions)
  #
  # Decision: a thin Net::HTTP client against OpenRouter's OpenAI-compatible
  # endpoint, not a provider SDK. The FeatureDetector interface is the real
  # contract; OpenRouter normalizes every model to the OpenAI request/response
  # shape, so one client serves all candidate models. Structured output uses
  # `response_format: {type: "json_schema"}`; the image is passed as an
  # image_url content part (the model fetches it server-side — see the SSRF
  # allowlist in validate_image_url!).
  # -----------------------------------------------------------------------

  def generate(system_instruction:, user_message:, image_url:, schema_name:, schema:, timeout: 30)
    raise ArgumentError, "OPENROUTER_API_KEY is not set" if @api_key.to_s.empty?

    body = build_request_body(system_instruction, user_message, image_url, schema_name, schema)
    http_post(URI(API_URL), body, timeout: timeout)
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    raise VlmTimeout, "OpenRouter #{@model} timed out: #{e.message}"
  end

  def build_request_body(system_instruction, user_message, image_url, schema_name, schema)
    {
      model: @model,
      messages: [
        { role: "system", content: system_instruction },
        {
          role: "user",
          content: [
            { type: "text", text: user_message },
            { type: "image_url", image_url: { url: image_url } }
          ]
        }
      ],
      response_format: {
        type: "json_schema",
        json_schema: { name: schema_name, strict: true, schema: schema }
      }
    }
  end

  def http_post(url, body, timeout: 30)
    request = Net::HTTP::Post.new(url)
    request["Content-Type"]  = "application/json"
    # Bearer token in the Authorization header — never in the URL, so it can't
    # leak into access/proxy logs or error-tracker URL capture.
    request["Authorization"] = "Bearer #{@api_key}"
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
    when 429, 500..599
      # Server overload / rate limit — a formatting retry can't help; route to the
      # same-prompt retry-once path instead of the sterner-prompt path.
      raise VlmServerError, "OpenRouter returned #{response.code}: #{response.body.to_s[0..200]}"
    else
      raise VlmNonJson, "OpenRouter returned #{response.code}: #{response.body.to_s[0..200]}"
    end
  rescue JSON::ParserError => e
    raise VlmNonJson, "OpenRouter response not parseable JSON: #{e.message}"
  end

  def extract_text(data)
    data.dig("choices", 0, "message", "content") || ""
  end

  # -----------------------------------------------------------------------
  # Helpers
  # -----------------------------------------------------------------------

  # Reject anything the model shouldn't be asked to fetch: non-HTTPS schemes,
  # control characters (prompt-injection smuggling), and hosts outside the
  # allowlist (SSRF — loopback, link-local 169.254.x metadata, internal hosts).
  def validate_image_url!(url)
    str = url.to_s
    raise ArgumentError, "image_tile_url contains control characters" if str.match?(/[[:cntrl:]]/)

    uri = begin
      URI.parse(str)
    rescue URI::InvalidURIError
      raise ArgumentError, "image_tile_url is not a valid URL"
    end

    raise ArgumentError, "image_tile_url must be https" unless uri.scheme == "https"
    raise ArgumentError, "image_tile_url has no host" if uri.host.to_s.empty?

    host = uri.host.downcase
    return if allowed_tile_hosts.any? { |suffix| host == suffix.delete_prefix(".") || host.end_with?(suffix) }

    raise ArgumentError, "image_tile_url host not allowed: #{host}"
  end

  def allowed_tile_hosts
    raw = ENV["IMAGE_TILE_HOST_ALLOWLIST"].to_s
    return DEFAULT_TILE_HOST_SUFFIXES if raw.strip.empty?

    raw.split(",").map { |h| h.strip.downcase }.reject(&:empty?)
  end

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
