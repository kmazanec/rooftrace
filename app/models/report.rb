# A shareable roof report. This models only the public-share token (ADR-016);
# the rendered report content + viewer (ADR-013) land later.
class Report < ApplicationRecord
  belongs_to :job, optional: true

  # Reports whose job was destroyed (job_id = nil). Surfacing this scope makes
  # the intentional job-survives-deletion design discoverable to maintenance tasks.
  scope :orphaned, -> { where(job_id: nil) }

  # One Report per Job (backed by the unique index on reports.job_id). Surfaces
  # the conflict as a validation error rather than a raw RecordNotUnique; the
  # index remains the real concurrency safeguard. allow_nil mirrors Postgres
  # treating multiple NULL job_ids as distinct (a Report may have no job).
  validates :job_id, uniqueness: true, allow_nil: true

  # Unguessable public share token (ADR-016) for /r/:token. has_secure_token
  # (SecureRandom.base58, 32 chars) + the DB unique index is the convention.
  has_secure_token :share_token, length: 32, on: :create

  def to_param
    share_token
  end
end
