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

  def initialize(base_url: ENV.fetch("SIDECAR_URL", "http://localhost:8000"),
                 shared_secret: ENV.fetch("SIDECAR_SHARED_SECRET"),
                 timeout: DEFAULT_TIMEOUT_SECONDS)
    @base_url = base_url
    @shared_secret = shared_secret
    @timeout = timeout
  end

  def skeleton(job_id:, sent_at:)
    post_json("/skeleton", { job_id: job_id, sent_at: sent_at.iso8601 })
  end

  private

  def post_json(path, payload)
    uri = URI.join(@base_url, path)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.read_timeout = @timeout
    http.open_timeout = @timeout

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "Bearer #{@shared_secret}"
    request.body = JSON.generate(payload)

    response = http.request(request)
    handle(response)
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    raise TimeoutError, "Sidecar #{path} timed out after #{@timeout}s: #{e.message}"
  end

  def handle(response)
    case response.code.to_i
    when 200..299
      JSON.parse(response.body)
    when 401
      raise AuthError, "Sidecar rejected the bearer token (401)"
    else
      raise Error, "Sidecar returned #{response.code}: #{response.body[0, 500]}"
    end
  end
end
