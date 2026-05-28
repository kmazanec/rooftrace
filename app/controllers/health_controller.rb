class HealthController < ApplicationController
  # F-01 walking-skeleton /health endpoint. Reports the Rails version, the
  # deployed git SHA, the current time, Postgres + PostGIS status, and
  # Spaces write+read success across all four buckets. Returns 200 only if
  # every component is ok; 503 otherwise so Kamal's healthcheck (and deploy
  # gate) fails fast on credential drift.
  def show
    pg_result = postgres_check
    spaces_result = spaces_check

    overall_ok = pg_result[:ok] && spaces_result.values.all? { |v| v == "ok" || v == "skipped" }

    payload = {
      status: overall_ok ? "ok" : "degraded",
      rails_version: Rails.version,
      git_sha: ENV.fetch("GIT_SHA", "unknown"),
      time: Time.current.iso8601,
      postgres: pg_result,
      spaces: spaces_result
    }

    render json: payload, status: (overall_ok ? :ok : :service_unavailable)
  end

  private

  def postgres_check
    row = ActiveRecord::Base.connection.execute("SELECT postgis_version()").first
    { ok: true, postgis_version: row["postgis_version"] }
  rescue StandardError => e
    { ok: false, error: e.message[0, 200] }
  end

  def spaces_check
    # Skip the Spaces probe entirely when explicitly disabled (compose-only dev
    # without real creds, or unit tests). Production always exercises it.
    return Hash[SpacesHealth::BUCKETS.zip(Array.new(SpacesHealth::BUCKETS.size, "skipped"))] if ENV["SKIP_SPACES_CHECK"] == "1"

    SpacesHealth.check_all
  rescue StandardError => e
    Hash[SpacesHealth::BUCKETS.zip(Array.new(SpacesHealth::BUCKETS.size, "fail: #{e.message[0, 150]}"))]
  end
end
