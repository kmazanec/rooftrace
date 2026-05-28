module JobsHelper
  # Ordered pipeline stages with human-readable labels.
  # Maps each Job status enum key → display label per the F-11 spec.
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
end
