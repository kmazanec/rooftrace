# Make the real Python sidecar available to specs that exercise the actual
# Rails ↔ sidecar IPC boundary (no mock). Two modes, by environment:
#
#   * CI: the sidecar runs as a SIBLING CONTAINER (its own test image) on the
#     job's docker network, and the job presets SIDECAR_URL to it. We do NOT
#     spawn anything — we connect to that URL and wait for it to be ready. This
#     is what lets the Rails suite run INSIDE the lean rails image (which has no
#     uv / Python). See .gitlab-ci.yml rails_test.
#   * Local dev: no SIDECAR_URL preset, so we spawn the sidecar as a subprocess
#     (`uv run uvicorn` — one command). This keeps `bundle exec rspec` working on
#     a developer laptop with nothing else running (the documented workflow).
#
# SKIP_REAL_SIDECAR=1 opts out of both (for iterating on unrelated specs).
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

    # True when SIDECAR_URL is preset (CI sibling-container mode): connect to it
    # instead of spawning a subprocess. A spawned local sidecar overwrites
    # @base_url with its own OS-assigned URL, so checking the env directly (not
    # @base_url) is what distinguishes the two modes.
    def preset_url
      url = ENV["SIDECAR_URL"]
      url unless url.nil? || url.empty?
    end

    # Bring the sidecar up for the suite. In CI (preset URL) this just waits for
    # the sibling container to be ready; locally it spawns the uv subprocess.
    def start!
      return if @pid || @base_url

      if (url = preset_url)
        @base_url = url
        wait_for_ready!
        return
      end

      # RoofTrace's running product (dev + prod) always uses REAL data; fixtures
      # are an explicit opt-DOWN that ONLY the test suites set (sidecar app/flags.py).
      # This spec subprocess MUST opt down every credentialed/heavy real path or it
      # would try real Mapbox imagery / 3DEP+pdal / Mapbox+Chromium / Modal at boot and the
      # suite would fail. STORAGE_LOCAL_ROOT points at the sidecar's own image-tile
      # fixtures (the same root its pytest conftest uses) so tile reads resolve.
      env = {
        "SIDECAR_SHARED_SECRET" => SHARED_SECRET,
        "IMAGERY_FIXTURE" => "1",
        "LIDAR_FIXTURE" => "1",
        "RENDER_IMAGES_FIXTURE" => "1",
        "PROJECT_PHOTO_FIXTURE" => "1",
        "SAM2_BACKEND" => "local",
        "STORAGE_LOCAL_ROOT" => ENV.fetch(
          "STORAGE_LOCAL_ROOT", SIDECAR_DIR.join("tests", "fixtures", "f07").to_s
        ),
        "WESM_FIXTURE_PATH" => ENV.fetch(
          "WESM_FIXTURE_PATH", SIDECAR_DIR.join("tests", "fixtures", "f06", "wesm_index.json").to_s
        )
      }

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
      # Preset-URL (CI sibling) mode owns no process — the CI job's after_script
      # tears the sibling container down. Only clear our handle.
      unless @pid
        @base_url = nil
        return
      end
      Process.kill("TERM", @pid)
    rescue Errno::ESRCH
      # already gone
    ensure
      Process.wait(@pid) rescue nil
      @pid = nil
      @base_url = nil
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
      # A sibling container (CI) may still be booting its conda/geo stack when the
      # Rails job starts, so allow longer there; a local subprocess is quick.
      timeout = preset_url ? 60 : 15
      Timeout.timeout(timeout) do
        loop do
          response = Net::HTTP.get_response(URI("#{@base_url}/health")) rescue nil
          return if response&.code == "200"
          sleep 0.1
        end
      end
    rescue Timeout::Error
      # No subprocess log in preset mode — the sibling's logs live in its own
      # container (the CI job dumps them on failure).
      detail = preset_url ? "" : "\nLog:\n#{File.read(LOG_PATH) rescue '(no log)'}"
      raise "Sidecar didn't become ready in #{timeout}s on #{@base_url}.#{detail}"
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
  # non-empty and a secret-based guard would skip — but SIDECAR_URL gets wiped,
  # leaving SidecarClient to fall back to http://localhost:8001, connect to
  # nothing, and 502 (no row written → the count-by-1 spec fails).
  #
  # Key the guard on RealSidecar.base_url (set in BOTH modes), not .pid: in the
  # preset-URL (CI sibling) mode there is no pid, so a pid-keyed guard would
  # never re-assert and autorestore would wipe SIDECAR_URL — the exact failure
  # above. base_url is the booted/connected sidecar in either mode.
  config.before(:each) do
    if RealSidecar.base_url && ENV["SIDECAR_URL"] != RealSidecar.base_url
      ENV["SIDECAR_URL"] = RealSidecar.base_url
      ENV["SIDECAR_SHARED_SECRET"] = RealSidecar::SHARED_SECRET
    end
  end

  config.after(:suite) do
    RealSidecar.stop! if ENV["SKIP_REAL_SIDECAR"] != "1"
  end
end
