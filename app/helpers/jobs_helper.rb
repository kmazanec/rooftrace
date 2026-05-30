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
end
