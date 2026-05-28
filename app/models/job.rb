# A roof-measurement job. F-03 models only what auth needs: the record's
# existence plus a job-scoped iOS capture token (ADR-016). The measurement
# pipeline fields and the submission flow land in F-10/F-11.
class Job < ApplicationRecord
  CAPTURE_TOKEN_TTL = 24.hours

  has_many :reports, dependent: :nullify
  has_many :measurements, dependent: :destroy

  # Pipeline status (C0.2). String-backed so the column reads as the status name;
  # the ordered set is the orchestrator's (F-10) progression and the seam the
  # F-11 status page renders. `failed` is terminal alongside `ready`.
  enum :status, {
    pending: "pending",
    resolving_address: "resolving_address",
    fetching_imagery: "fetching_imagery",
    fetching_lidar: "fetching_lidar",
    refining_outline: "refining_outline",
    detecting_features: "detecting_features",
    fitting_planes: "fitting_planes",
    ready: "ready",
    failed: "failed"
  }, default: "pending"

  # Unguessable job-scoped iOS bearer token (ADR-016). Rails' has_secure_token
  # (SecureRandom.base58, 32 chars ≈ 187 bits) + the DB unique index on the
  # column is the convention — collisions are astronomically unlikely and not
  # retried. Generated on create so it's assigned alongside its expiry.
  has_secure_token :capture_token, length: 32, on: :create
  before_validation :assign_capture_token_expiry, on: :create

  # Resolve a job by a presented capture token, rejecting expired ones.
  # Returns nil when the token is unknown or past its TTL.
  def self.authenticate_capture_token(token)
    return nil if token.blank?

    job = find_by(capture_token: token)
    return nil if job.nil? || job.capture_token_expired?

    job
  end

  def capture_token_expired?
    capture_token_expires_at.nil? || capture_token_expires_at <= Time.current
  end

  # The most recently generated Measurement for this job (by `generated_at`).
  def latest_measurement
    measurements.order(generated_at: :desc).first
  end

  # Persist a status transition and broadcast it to the job's own Turbo stream
  # so the status page live-updates (C0.2 — the orchestration<->status-page
  # seam). Raises ArgumentError on an unknown status rather than silently
  # no-opping.
  #
  # `broadcast:` lets a caller commit the status update inside a DB transaction
  # and then publish the Turbo broadcast AFTER commit (an ActionCable publish
  # must not be held inside an open transaction): pass `broadcast: false` for the
  # in-transaction status change, then call `broadcast_status!` once committed.
  def advance_to!(status, broadcast: true)
    raise ArgumentError, "unknown job status: #{status.inspect}" unless self.class.statuses.key?(status.to_s)

    # A terminal job (ready/failed) must never be resurrected by a later
    # transition — e.g. a duplicate GeometryJob run for an already-failed job.
    # fail_with! is exempt: it is the transition INTO terminal, not out of it.
    if terminal?
      raise ArgumentError, "cannot advance a terminal job (#{self.status}) to #{status}"
    end

    update!(status: status.to_s)
    broadcast_status if broadcast
  end

  # Public hook to fire the status broadcast after a transaction commits (used
  # alongside `advance_to!(..., broadcast: false)`).
  def broadcast_status!
    broadcast_status
  end

  # Move the job to `failed`, recording `message` in `last_error`, and broadcast.
  def fail_with!(message)
    update!(status: "failed", last_error: message)
    broadcast_status
  end

  # A job is terminal once it has succeeded (`ready`) or failed (`failed`).
  def terminal?
    ready? || failed?
  end

  private

  # Replace the per-job status partial on the `[self, :status]` Turbo stream.
  # F-11 subscribes to this exact stream and renders `jobs/_status` into
  # `dom_id(self, :status)`.
  def broadcast_status
    broadcast_replace_to(
      [ self, :status ],
      target: ActionView::RecordIdentifier.dom_id(self, :status),
      partial: "jobs/status",
      locals: { job: self }
    )
  end

  def assign_capture_token_expiry
    self.capture_token_expires_at ||= CAPTURE_TOKEN_TTL.from_now
  end
end
