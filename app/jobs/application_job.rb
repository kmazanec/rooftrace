class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # DeserializationError (GlobalID lookup fails) is a subset of RecordNotFound
  # and is covered by the active discard below — no separate clause needed.
  # discard_on ActiveJob::DeserializationError

  # A job whose target record was deleted between enqueue and run can never
  # succeed, so don't burn the bounded retry budget on it — discard immediately.
  discard_on ActiveRecord::RecordNotFound
end
