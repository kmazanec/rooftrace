# A guided iOS walk-around capture uploaded against a Job (ADR-007: the iOS app
# is a thin capture client; all fusion math is server-side). One row per
# completed capture session, linked to the Job whose measurement the on-site
# capture refines. `session_id` is generated once on the device at session start
# and is stable across upload retries, so a unique index on it makes the ingest
# endpoint idempotent (a re-POST of the same bundle finds the existing row rather
# than creating a duplicate and re-enqueuing fusion).
class CaptureSession < ApplicationRecord
  belongs_to :job
  has_many :captures, dependent: :destroy

  validates :session_id, presence: true, uniqueness: true
  validates :manifest_version, presence: true
end
