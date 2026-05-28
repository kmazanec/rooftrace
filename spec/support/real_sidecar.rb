# Boot the real Python sidecar as a subprocess for tests that need to
# exercise the actual Rails ↔ sidecar IPC boundary. Per F-01 feature spec:
# "the sidecar in CI runs as a sibling docker-compose service so the test
# exercises the real IPC boundary, not a mock." Locally we use a subprocess
# (which `uv` makes one command); CI does the same via docker-compose.
require "net/http"
require "socket"
require "timeout"
require "open3"

module RealSidecar
  SIDECAR_DIR = Rails.root.join("sidecar")
  SHARED_SECRET = ENV.fetch("SIDECAR_SHARED_SECRET", "test-shared-secret")

  class << self
    attr_reader :pid, :port, :base_url

    def start!
      return if @pid

      @port = pick_free_port
      @base_url = "http://127.0.0.1:#{@port}"
      env = { "SIDECAR_SHARED_SECRET" => SHARED_SECRET }

      # `uv run uvicorn` resolves the venv automatically.
      @pid = Process.spawn(
        env,
        "uv", "run", "uvicorn", "app.main:app",
        "--host", "127.0.0.1", "--port", @port.to_s, "--log-level", "warning",
        chdir: SIDECAR_DIR.to_s,
        out: File.open("/tmp/rooftrace-sidecar-test.log", "w"),
        err: %i[child out]
      )

      wait_for_ready!
    end

    def stop!
      return unless @pid
      Process.kill("TERM", @pid)
    rescue Errno::ESRCH
      # already gone
    ensure
      Process.wait(@pid) rescue nil
      @pid = nil
    end

    private

    def pick_free_port
      socket = TCPServer.new("127.0.0.1", 0)
      port = socket.addr[1]
      socket.close
      port
    end

    def wait_for_ready!
      Timeout.timeout(15) do
        loop do
          response = Net::HTTP.get_response(URI("#{@base_url}/health")) rescue nil
          return if response&.code == "200"
          sleep 0.1
        end
      end
    rescue Timeout::Error
      log = File.read("/tmp/rooftrace-sidecar-test.log") rescue "(no log)"
      raise "Sidecar didn't become ready in 15s on #{@base_url}. Log:\n#{log}"
    end
  end
end

RSpec.configure do |config|
  config.before(:suite) do
    if ENV["SKIP_REAL_SIDECAR"] != "1"
      RealSidecar.start!
      ENV["SIDECAR_URL"] = RealSidecar.base_url
      ENV["SIDECAR_SHARED_SECRET"] = RealSidecar::SHARED_SECRET
    end
  end

  config.after(:suite) do
    RealSidecar.stop! if ENV["SKIP_REAL_SIDECAR"] != "1"
  end
end
