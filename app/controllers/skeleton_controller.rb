class SkeletonController < ApplicationController
  # Diagnostic round-trip endpoint; not a contractor surface.
  skip_before_action :require_demo_login

  # Walking-skeleton endpoint. Round-trips Rails → sidecar → Postgres and
  # returns the persisted row id, proving the full IPC + persistence path works
  # end-to-end. No business logic; the trivial payload will eventually be
  # replaced with the real pipeline schema contract.
  def show
    job_id = SecureRandom.uuid
    rails_sent_at = Time.current

    sidecar_response = SidecarClient.new.skeleton(job_id: job_id, sent_at: rails_sent_at)
    rails_received_at = Time.current

    sidecar_received_at = parse_sidecar_timestamp(sidecar_response)

    ping = SkeletonPing.create!(
      job_id: job_id,
      rails_sent_at: rails_sent_at,
      sidecar_received_at: sidecar_received_at,
      rails_received_at: rails_received_at,
      rtt_ms: ((rails_received_at - rails_sent_at) * 1000).to_i,
      sidecar_payload: sidecar_response
    )

    render json: {
      ping_id: ping.id,
      job_id: job_id,
      rails_received_at: rails_received_at.iso8601,
      sidecar_response: sidecar_response,
      db_row: { id: ping.id, created_at: ping.created_at.iso8601 }
    }
  rescue SidecarClient::Error => e
    # Sidecar unreachable / auth failure / bad upstream — surface a clean 502
    # rather than a 500 stack trace.
    render json: { error: "sidecar unavailable", detail: e.class.name }, status: :bad_gateway
  rescue ActiveRecord::ActiveRecordError => e
    # DB write failed after a successful sidecar call — surface a clean 5xx
    # instead of leaking a stack trace. (Partial state — sidecar ran, no row —
    # is acceptable for this stateless walking-skeleton endpoint.)
    Rails.logger.error("[skeleton] DB write failed: #{e.class}: #{e.message}")
    render json: { error: "persistence failed", detail: e.class.name }, status: :internal_server_error
  end

  private

  # The sidecar's timestamp is untrusted input from across the IPC boundary.
  # Reject anything that isn't a strict ISO-8601 timestamp instead of letting
  # Time.parse raise an uncaught ArgumentError (which would 500 the request and
  # make /skeleton trivially crashable by a misbehaving sidecar).
  def parse_sidecar_timestamp(sidecar_response)
    raw = sidecar_response.fetch("received_at") { nil }
    Time.iso8601(raw.to_s)
  rescue ArgumentError, TypeError
    raise SidecarClient::Error, "sidecar returned a malformed received_at timestamp"
  end
end
