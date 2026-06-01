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
    summary.merge(last_error: last_error)
  end

  private

  attr_reader :job

  def share_token
    job.report&.share_token
  end

  def last_error
    job.failed? ? job.last_error : nil
  end
end
