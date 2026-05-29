require "rails_helper"

RSpec.describe FusionJob, type: :job do
  let(:job) { create(:job, status: "ready") }
  let(:capture_session) { create(:capture_session, job: job) }
  let!(:prior) do
    create(:measurement, job: job, source: "lidar", confidence: 0.8,
                         lidar: { "status" => "LIDAR_AVAILABLE" }, generated_at: 2.minutes.ago)
  end

  it "delegates to FusionOrchestrator on the happy path" do
    expect(FusionOrchestrator).to receive(:call).with(job, capture_session)
    described_class.new.perform(job.id, capture_session.id)
  end

  it "skips re-running when the latest measurement is already fused (idempotency)" do
    create(:measurement, job: job, source: "lidar+device+imagery", confidence: 0.9,
                         generated_at: 1.minute.ago)
    expect(FusionOrchestrator).not_to receive(:call)
    described_class.new.perform(job.id, capture_session.id)
  end

  describe "failure handling" do
    before { allow(FusionOrchestrator).to receive(:call).and_raise(StandardError.new("boom")) }

    it "records last_error WITHOUT a terminal status on an intermediate attempt" do
      fusion = described_class.new
      allow(fusion).to receive(:executions).and_return(1)
      expect { fusion.perform(job.id, capture_session.id) }.to raise_error(StandardError)
      expect(job.reload.status).to eq("ready")
      expect(job.last_error).to include("Fusion crashed")
    end

    it "appends fusion_job_exhausted on the final attempt and re-raises, status still ready" do
      fusion = described_class.new
      allow(fusion).to receive(:executions).and_return(described_class::MAX_ATTEMPTS)
      expect { fusion.perform(job.id, capture_session.id) }.to raise_error(StandardError)
      expect(prior.reload.warnings).to include("fusion_job_exhausted")
      expect(job.reload.status).to eq("ready")
    end
  end
end
