# A roof-measurement job. F-03 models only what auth needs: the record's
# existence plus a job-scoped iOS capture token (ADR-016). The measurement
# pipeline fields and the submission flow land in F-10/F-11.
class Job < ApplicationRecord
  CAPTURE_TOKEN_TTL = 24.hours

  has_many :reports, dependent: :nullify

  before_validation :assign_capture_token, on: :create

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

  private

  def assign_capture_token
    self.capture_token ||= TokenGenerator.token
    self.capture_token_expires_at ||= CAPTURE_TOKEN_TTL.from_now
  end
end
