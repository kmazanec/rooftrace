class HealthController < ApplicationController
  # Public readiness probe (deploy gate) — must never require a login.
  skip_before_action :require_demo_login

  # Walking-skeleton /health endpoint. Reports the Rails version, the
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
    # /health is public + unauthenticated — never echo the raw exception
    # message (it can leak connection strings, hostnames, credentials). Log
    # the detail server-side; surface only a static signal.
    Rails.logger.error("[health] postgres check failed: #{e.class}: #{e.message}")
    { ok: false, error: "postgres check failed" }
  end

  def spaces_check
    # Skip the Spaces probe entirely when explicitly disabled (compose-only dev
    # without real creds, or unit tests). Production always exercises it.
    return Hash[SpacesHealth::BUCKETS.zip(Array.new(SpacesHealth::BUCKETS.size, "skipped"))] if ENV["SKIP_SPACES_CHECK"] == "1"

    # /health is public and may be polled frequently; each full probe is 12 S3
    # calls. Cache the result for 60s so polling can't amplify into S3 cost or
    # a DoS vector. The container *liveness* check uses the cheap /up endpoint
    # (no S3) — this /health is the richer readiness/deploy-gate check.
    Rails.cache.fetch("health/spaces", expires_in: 60.seconds) { SpacesHealth.check_all }
  rescue StandardError => e
    # Same rationale as postgres_check: don't leak AWS error detail (it can
    # include the access key id, bucket name, endpoint) on a public endpoint.
    Rails.logger.error("[health] spaces check raised: #{e.class}: #{e.message}")
    Hash[SpacesHealth::BUCKETS.zip(Array.new(SpacesHealth::BUCKETS.size, "fail"))]
  end
end
