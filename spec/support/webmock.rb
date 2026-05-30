# WebMock net-connect policy for the suite.
#
# The feature-detection spec requires "webmock/rspec", which disables ALL real
# net connections suite-wide. But the skeleton / pipeline round-trip specs talk
# to the real sidecar. So once WebMock is loaded, we re-allow connections to the
# sidecar (and nothing else): any other non-localhost HTTP (e.g. a live VLM call)
# still raises unless explicitly stubbed — exactly the safety we want in CI.
#
# Two sidecar topologies (see spec/support/real_sidecar.rb):
#   * Local: the sidecar is a uvicorn subprocess on localhost → allow_localhost.
#   * CI: the sidecar is a SIBLING CONTAINER at the SIDECAR_URL host (e.g.
#     "sidecar"), which is NOT localhost. Webmock would block it, so we add that
#     host to the allowlist explicitly when SIDECAR_URL is preset.
RSpec.configure do |config|
  config.before(:suite) do
    if defined?(WebMock)
      allowed = []
      if (url = ENV["SIDECAR_URL"]).to_s != ""
        host = begin
          URI.parse(url).host
        rescue URI::InvalidURIError
          nil
        end
        allowed << host if host && !%w[localhost 127.0.0.1].include?(host)
      end
      WebMock.disable_net_connect!(allow_localhost: true, allow: allowed)
    end
  end
end
