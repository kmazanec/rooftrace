# One projected on-site overlay per Capture: the result of projecting the
# measured facets/features onto that capture's photo (pinhole projection with
# z-buffer occlusion). The composite + SVG refs are Spaces
# `artifacts/<job_id>/projected/` object keys. `pose_confidence` is surfaced
# verbatim (honest-uncertainty); `low_pose_confidence` flags an overlay the
# surfaces should dim. `occluded_facet_ids` lists facets fully behind a nearer
# surface in this photo.
class ProjectedOverlay < ApplicationRecord
  belongs_to :capture

  # All overlays for a given job, reached through the capture -> capture_session chain.
  scope :for_job, ->(job) { joins(capture: :capture_session).where(capture_sessions: { job_id: job.id }) }
end
