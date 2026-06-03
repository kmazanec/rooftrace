module JobsHelper
  # Ordered pipeline stages with human-readable labels.
  # Maps each Job status enum key → display label shown on the status page.
  # "Show its work" — visible in the status page as the pipeline progresses.
  def job_pipeline_stages
    [
      [ :resolving_address,  "Looking up address" ],
      [ :fetching_imagery,   "Fetching imagery" ],
      [ :fetching_lidar,     "Fetching LiDAR" ],
      [ :refining_outline,   "Refining roof outline" ],
      [ :detecting_features, "Detecting features" ],
      [ :fitting_planes,     "Computing measurement" ]
    ]
  end

  # Maps every Job status enum key to its ordinal position in the enum definition.
  # Used by _status.html.erb to determine whether a pipeline stage is completed,
  # active, or pending relative to the job's current status.
  # Returns e.g. { "pending" => 0, "resolving_address" => 1, ... "failed" => 8 }.
  def job_status_index
    Job.statuses.keys.each_with_index.to_h
  end

  # Status badge for the jobs-list row, mirroring the iOS StatusIndicator: a
  # `kind` (working | done | failed) that drives the badge color, plus a
  # human-readable label. In-progress stages reuse job_pipeline_stages' labels;
  # pending is "Queued", ready is "Ready", failed is "Failed".
  StatusBadge = Struct.new(:kind, :label)

  def job_status_badge(job)
    case job.status.to_sym
    when :ready
      StatusBadge.new(:done, "Ready")
    when :failed
      StatusBadge.new(:failed, "Failed")
    when :pending
      StatusBadge.new(:working, "Queued")
    else
      label = job_pipeline_stages.to_h[job.status.to_sym] || job.status.to_s.humanize
      StatusBadge.new(:working, label)
    end
  end

  # Where a job-list row navigates: the report for a finished job, otherwise the
  # live status page (a failed job's status page shows the error + retry).
  def job_row_path(job)
    job.ready? ? report_job_path(job) : job_path(job)
  end
end
