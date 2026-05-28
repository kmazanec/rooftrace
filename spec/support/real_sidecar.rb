# Boot the real Python sidecar as a subprocess for tests that need to
# exercise the actual Rails ↔ sidecar IPC boundary, rather than a mock:
# the sidecar in CI runs as a sibling docker-compose service so the test
# exercises the real IPC boundary. Locally we use a subprocess
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

    LOG_PATH = "/tmp/rooftrace-sidecar-test.log".freeze

    def start!
      return if @pid

      env = { "SIDECAR_SHARED_SECRET" => SHARED_SECRET }

      # Bind --port 0 so the OS assigns a free port atomically at bind time
      # (no TOCTOU race between picking a port and uvicorn binding it). We then
      # read the actual port back from uvicorn's startup log.
      File.write(LOG_PATH, "")
      @pid = Process.spawn(
        env,
        "uv", "run", "uvicorn", "app.main:app",
        "--host", "127.0.0.1", "--port", "0", "--log-level", "info",
        chdir: SIDECAR_DIR.to_s,
        out: File.open(LOG_PATH, "w"),
        err: %i[child out]
      )

      @port = read_bound_port!
      @base_url = "http://127.0.0.1:#{@port}"
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

    # Read the OS-assigned port from uvicorn's startup line, e.g.
    #   "Uvicorn running on http://127.0.0.1:54321 (Press CTRL+C to quit)"
    def read_bound_port!
      Timeout.timeout(15) do
        loop do
          log = File.read(LOG_PATH) rescue ""
          if (m = log.match(%r{Uvicorn running on https?://127\.0\.0\.1:(\d+)}))
            return Integer(m[1])
          end
          raise "uvicorn exited before binding. Log:\n#{log}" unless process_alive?
          sleep 0.05
        end
      end
    rescue Timeout::Error
      raise "Sidecar didn't report a bound port in 15s. Log:\n#{File.read(LOG_PATH) rescue '(no log)'}"
    end

    def process_alive?
      Process.kill(0, @pid)
      true
    rescue Errno::ESRCH
      false
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
      log = File.read(LOG_PATH) rescue "(no log)"
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

  # Re-assert the sidecar ENV vars before every example. dotenv-rails'
  # test-env autorestore resets ENV to its pre-suite snapshot between examples,
  # which wipes the vars before(:suite) set. We must key the re-assert on
  # SIDECAR_URL, NOT SIDECAR_SHARED_SECRET: in CI the job env already carries
  # SIDECAR_SHARED_SECRET (=ci-shared-secret), so autorestore keeps it
  # non-empty and a secret-based guard would skip — but SIDECAR_URL (set only
  # by the suite, OS-assigned port) gets wiped, leaving SidecarClient to fall
  # back to http://localhost:8001, connect to nothing, and 502 (no row written
  # → the count-by-1 spec fails). Always re-assert both whenever the URL drifts
  # from the booted sidecar's.
  config.before(:each) do
    if RealSidecar.pid && ENV["SIDECAR_URL"] != RealSidecar.base_url
      ENV["SIDECAR_URL"] = RealSidecar.base_url
      ENV["SIDECAR_SHARED_SECRET"] = RealSidecar::SHARED_SECRET
    end
  end

  config.after(:suite) do
    RealSidecar.stop! if ENV["SKIP_REAL_SIDECAR"] != "1"
  end
end
