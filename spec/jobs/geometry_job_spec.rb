require "rails_helper"

RSpec.describe GeometryJob, type: :job do
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

  describe "unexpected failures" do
    it "marks the job failed and re-raises for the queue's retry/dead-set" do
      allow(MeasurementOrchestrator).to receive(:call).and_raise(RuntimeError, "boom")

      expect { described_class.perform_now(job.id) }.to raise_error(RuntimeError, "boom")
      expect(job.reload.status).to eq("failed")
      expect(job.last_error).to match(/crashed/i)
    end
  end
end
