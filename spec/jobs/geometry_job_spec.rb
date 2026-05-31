require "rails_helper"

RSpec.describe GeometryJob, type: :job do
  include ActiveJob::TestHelper

  let(:job) { create(:job) }

  it "loads the job and runs the orchestrator" do
    orchestrator = instance_double(MeasurementOrchestrator)
    expect(MeasurementOrchestrator).to receive(:call) do |arg|
      expect(arg).to be_a(Job)
      expect(arg.id).to eq(job.id)
      build(:measurement, job: job)
    end

    described_class.perform_now(job.id)
  end

  it "enqueues on the default queue" do
    expect { described_class.perform_later(job.id) }
      .to have_enqueued_job(described_class).on_queue("default").with(job.id)
  end

  describe "expected failures (do not retry)" do
    it "lets the orchestrator's terminal fail_with! stand without raising" do
      # The orchestrator handles expected failures itself and returns nil.
      allow(MeasurementOrchestrator).to receive(:call) do |j|
        j.fail_with!("No building footprint found for this address.")
        nil
      end

      expect { described_class.perform_now(job.id) }.not_to raise_error
      expect(job.reload.status).to eq("failed")
    end
  end

  describe "terminal-job guard" do
    it "is a no-op for an already-failed job (does not run the orchestrator)" do
      job.fail_with!("previously failed")
      expect(MeasurementOrchestrator).not_to receive(:call)

      expect { described_class.perform_now(job.id) }.not_to raise_error
      expect(job.reload.status).to eq("failed")
    end

    it "is a no-op for an already-ready job" do
      job.update!(status: "ready")
      expect(MeasurementOrchestrator).not_to receive(:call)

      described_class.perform_now(job.id)
      expect(job.reload.status).to eq("ready")
    end
  end

  describe "deleted job (discard, do not retry)" do
    it "discards rather than raising when the job id no longer exists" do
      expect(MeasurementOrchestrator).not_to receive(:call)
      expect { described_class.perform_now(SecureRandom.uuid) }.not_to raise_error
    end
  end

  describe "unexpected failures (retryable)" do
    # An unexpected error must let Solid Queue's bounded retry actually re-run the
    # pipeline. The bug this guards: marking the Job terminal (fail_with!) before
    # re-raising defeated the retry — the re-run hit `return if job.terminal?` and
    # no-opped, permanently failing after a single real attempt. So an
    # intermediate attempt stays NON-terminal (records last_error); only the
    # final attempt (executions >= MAX_ATTEMPTS) marks the Job failed.

    it "is configured with a bounded retry_on policy" do
      # MAX_ATTEMPTS keys the rescue's terminal/non-terminal decision off the
      # same bound retry_on uses, so the two can't drift.
      expect(described_class::MAX_ATTEMPTS).to be >= 2
    end

    it "on an intermediate attempt records last_error but leaves the Job NON-terminal" do
      allow(MeasurementOrchestrator).to receive(:call).and_raise(RuntimeError, "boom")

      # Attempt 1 (executions becomes 1, < MAX_ATTEMPTS): retry_on reschedules, so
      # nothing propagates out of perform_now, but the Job must stay retryable.
      expect { described_class.perform_now(job.id) }.not_to raise_error

      expect(job.reload).not_to be_terminal
      expect(job.status).to eq("pending")
      expect(job.last_error).to match(/crashed.*attempt 1/i)
      # A retry was actually scheduled.
      expect(enqueued_jobs.size).to eq(1)
    end

    it "a SECOND perform (the retry) actually RE-RUNS the orchestrator (terminal guard does not block it)" do
      call_count = 0
      allow(MeasurementOrchestrator).to receive(:call) do
        call_count += 1
        raise RuntimeError, "transient boom"
      end

      # Attempt 1: runs, stays non-terminal.
      described_class.perform_now(job.id)
      expect(call_count).to eq(1)
      expect(job.reload).not_to be_terminal

      # Attempt 2 (the retry: ActiveJob increments executions to 2): MUST re-run
      # the orchestrator. If attempt 1 had gone terminal, this would no-op.
      retried = described_class.new(job.id)
      retried.executions = 1
      retried.perform_now
      expect(call_count).to eq(2)
      expect(job.reload).not_to be_terminal
    end

    it "on the FINAL attempt marks the Job failed (terminal) and lets the error propagate" do
      allow(MeasurementOrchestrator).to receive(:call).and_raise(RuntimeError, "boom")

      final = described_class.new(job.id)
      # Mirror a real final attempt: in production Solid Queue persists and
      # increments BOTH the global executions and retry_on's per-exception
      # counter on each attempt, so they stay in lockstep. Set both to one below
      # the bound; perform_now increments executions to MAX_ATTEMPTS and
      # retry_on's executions_for to MAX_ATTEMPTS, so retry_on stops retrying.
      final.executions = described_class::MAX_ATTEMPTS - 1
      final.exception_executions = { "[StandardError]" => described_class::MAX_ATTEMPTS - 1 }

      expect { final.perform_now }.to raise_error(RuntimeError, "boom")
      expect(job.reload.status).to eq("failed")
      expect(job.last_error).to match(/crashed/i)
    end
  end
end
