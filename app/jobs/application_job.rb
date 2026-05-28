class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  # A job whose target record was deleted between enqueue and run can never
  # succeed, so don't burn the bounded retry budget on it — discard immediately.
  discard_on ActiveRecord::RecordNotFound
end
