require "rails_helper"

RSpec.describe ProjectionJob, type: :job do
  let(:job) { create(:job, status: "ready") }

  it "delegates to ProjectionOrchestrator" do
    expect(ProjectionOrchestrator).to receive(:call).with(job)
    described_class.new.perform(job.id)
  end

  it "never changes the job status on a transient failure (projection is additive)" do
    allow(ProjectionOrchestrator).to receive(:call).and_raise(SidecarClient::Error.new("boom"))
    proj = described_class.new
    allow(proj).to receive(:executions).and_return(1)
    expect { proj.perform(job.id) }.to raise_error(SidecarClient::Error)
    expect(job.reload.status).to eq("ready")
  end

  it "is enqueued on the default queue" do
    expect(described_class.new.queue_name).to eq("default")
  end

  it "records last_error on an intermediate attempt and re-raises" do
    allow(ProjectionOrchestrator).to receive(:call).and_raise(StandardError.new("boom"))
    proj = described_class.new
    allow(proj).to receive(:executions).and_return(1)
    expect { proj.perform(job.id) }.to raise_error(StandardError)
    expect(job.reload.last_error).to include("Projection crashed")
  end
end
