# One photo+depth+pose sample inside a CaptureSession (ADR-007). `sequence_index`
# is the capture_index from the session manifest (the order the guided prompts
# were shot in). Photo/depth refs are Spaces `uploads/` object keys; the pose
# columns hold the per-frame camera intrinsics/extrinsics a later AR-overlay
# stage projects facets through.
class Capture < ApplicationRecord
  belongs_to :capture_session
  has_one :projected_overlay, dependent: :destroy

  validates :sequence_index, presence: true

  scope :for_job, ->(job) { joins(:capture_session).where(capture_sessions: { job_id: job.id }) }
  scope :with_photo, -> { where.not(photo_ref: nil).order(:sequence_index) }
end
