require "net/http"
require "uri"
require "json"

# Talks to the Python FastAPI sidecar over the internal Docker network.
# F-01 exposes only `skeleton`; F-02 will add `pipeline_run` and the rest of
# the real pipeline contract.
#
# Auth: every request includes `Authorization: Bearer <SIDECAR_SHARED_SECRET>`
# per ADR-008. The sidecar rejects with 401 otherwise.
class SidecarClient
  class Error < StandardError; end
  class AuthError < Error; end
  class TimeoutError < Error; end

  DEFAULT_TIMEOUT_SECONDS = 5

  def self.skeleton(job_id:, sent_at:)
    new.skeleton(job_id: job_id, sent_at: sent_at)
  end

  def initialize(base_url: nil, shared_secret: nil, timeout: DEFAULT_TIMEOUT_SECONDS)
    @base_url = base_url || ENV["SIDECAR_URL"] || "http://localhost:8000"
    @shared_secret = shared_secret || ENV["SIDECAR_SHARED_SECRET"]
    @timeout = timeout
    raise ArgumentError, "SIDECAR_SHARED_SECRET is unset; refusing to call sidecar without auth" if @shared_secret.to_s.empty?
  end

  def skeleton(job_id:, sent_at:)
    post_json("/skeleton", { job_id: job_id, sent_at: sent_at.iso8601 })
  end

  private

  def post_json(path, payload)
    uri = URI.join(@base_url, path)

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "Bearer #{@shared_secret}"
    request.body = JSON.generate(payload)

    # Use the block form so BOTH open_timeout and read_timeout are honored
    # (open_timeout is silently ignored on the implicit single-shot
    # Net::HTTP.new#request path) and the socket is closed deterministically.
    response = Net::HTTP.start(uri.host, uri.port,
                               use_ssl: uri.scheme == "https",
                               open_timeout: @timeout,
                               read_timeout: @timeout) do |http|
      http.request(request)
    end
    handle(response)
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    raise TimeoutError, "Sidecar #{path} timed out after #{@timeout}s: #{e.message}"
  rescue SystemCallError => e
    # Connection refused / reset / host unreachable, etc.
    raise Error, "Sidecar #{path} connection failed: #{e.class}"
  end

  def handle(response)
    case response.code.to_i
    when 200..299
      parse_body(response.body)
    when 401
      raise AuthError, "Sidecar rejected the bearer token (401)"
    else
      raise Error, "Sidecar returned #{response.code}"
    end
  end

  def parse_body(body)
    JSON.parse(body.to_s)
  rescue JSON::ParserError
    raise Error, "Sidecar returned a non-JSON body"
  end
end
