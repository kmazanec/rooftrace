class SkeletonPing < ApplicationRecord
  # job_id is an intentional LOOSE string reference — no belongs_to, no FK.
  # SkeletonPing records a fabricated test UUID; there is no real Job row to join.
  validates :job_id, presence: true
  validates :rails_sent_at, :sidecar_received_at, :rails_received_at, presence: true
  validates :rtt_ms, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
