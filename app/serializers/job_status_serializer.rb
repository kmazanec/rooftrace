class JobStatusSerializer
  def self.summary(job)
    new(job).summary
  end

  def self.detail(job)
    new(job).detail
  end

  def initialize(job)
    @job = job
  end

  def summary
    {
      id: job.id,
      address: job.address,
      status: job.status,
      created_at: job.created_at.iso8601,
      ready: job.ready?,
      share_token: share_token
    }
  end

  def detail
    summary.merge(last_error: last_error, **capture_credential)
  end

  private

  attr_reader :job

  def share_token
    job.report&.share_token
  end

  # The iOS app recovers the scan credential straight from the status response so
  # it can offer the LiDAR walk-around on any job it opens, not just freshly
  # created ones. Omitted once expired so the client never builds a dead handoff.
  def capture_credential
    return {} if job.capture_token_expired?

    {
      capture_token: job.capture_token,
      capture_token_expires_at: job.capture_token_expires_at.iso8601
    }
  end

  def last_error
    job.failed? ? job.last_error : nil
  end
end
