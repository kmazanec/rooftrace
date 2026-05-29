# WebMock net-connect policy for the suite.
#
# The feature-detection spec requires "webmock/rspec", which disables ALL real
# net connections suite-wide. But the skeleton / pipeline round-trip specs talk to a
# real uvicorn sidecar subprocess on localhost. So once WebMock is loaded, we
# re-allow localhost globally: the real-sidecar specs keep working, while any
# non-localhost HTTP (e.g. a live Gemini call) still raises unless explicitly
# stubbed — which is exactly the safety we want in CI.
RSpec.configure do |config|
  config.before(:suite) do
    if defined?(WebMock)
      WebMock.disable_net_connect!(allow_localhost: true)
    end
  end
end
