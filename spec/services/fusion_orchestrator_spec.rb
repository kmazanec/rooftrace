require "rails_helper"

# FusionOrchestrator unit tests. SidecarClient is stubbed; the unit under test is
# the additive-fusion orchestration logic. The load-bearing invariant the suite
# pins: the job's :ready status is NEVER touched (no advance_to!/fail_with!), on
# any path — success, ICP failure, or sidecar error.
RSpec.describe FusionOrchestrator, type: :service do
  let(:job) { create(:job, status: "ready") }
  let(:capture_session) { create(:capture_session, job: job) }
  let(:sidecar) { class_double(SidecarClient) }

  let(:prior_lidar) do
    {
      "status" => "LIDAR_AVAILABLE",
      "point_array_ref" => "cache/#{job.id}/points.npy",
      "point_count" => 48_213,
      "source" => "lidar",
      "confidence" => 0.95
    }
  end

  let!(:prior) do
    create(:measurement, job: job, source: "lidar", confidence: 0.8,
                         lidar: prior_lidar, warnings: [], generated_at: 2.minutes.ago)
  end

  subject(:orchestrator) { described_class.new(job, capture_session, sidecar: sidecar) }

  def fuse_response(rmse: 0.05, with_measurement: true)
    measurement = if with_measurement
      {
        "job_id" => job.id,
        "facets" => [ {
          "facet_id" => "F1",
          "vertices" => [ [ -96.70258, 40.81362 ], [ -96.7024, 40.81361 ], [ -96.70241, 40.81375 ] ],
          "pitch_ratio" => 6.0, "pitch_degrees" => 26.57, "area_sq_ft" => 712.4,
          "source" => "fusion", "confidence" => 0.96
        } ],
        "features" => [],
        "total_area_sq_ft" => 712.4,
        "predominant_pitch_ratio" => 6.0,
        "source" => "fusion",
        "confidence" => 0.96
      }
    end
    { "pipelineSchemaVersion" => "0.3.0", "job_id" => job.id,
      "measurement" => measurement, "icp_rmse_m" => rmse }
  end

  describe "happy path (ICP converges)" do
    before do
      allow(sidecar).to receive(:fuse_capture).and_return(fuse_response(rmse: 0.05))
    end

    it "creates a NEW additive Measurement with the fused source" do
      expect { orchestrator.call }.to change { job.measurements.count }.by(1)
      expect(job.reload.latest_measurement.source).to eq("lidar+device+imagery")
    end

    it "raises confidence above the prior (>= prior)" do
      orchestrator.call
      expect(job.reload.latest_measurement.confidence.to_f).to be >= prior.confidence.to_f
    end

    it "leaves the prior LiDAR-only measurement intact" do
      orchestrator.call
      expect(prior.reload.source).to eq("lidar")
      expect(prior.warnings).to be_empty
    end

    it "records fusion provenance keys" do
      orchestrator.call
      prov = job.reload.latest_measurement.provenance
      expect(prov["fusion_icp_rmse_m"]).to eq(0.05)
      expect(prov["fusion_session_id"]).to eq(capture_session.id)
      expect(prov["fusion_capture_mesh_ref"]).to eq(capture_session.world_mesh_ref)
    end

    it "does not copy the prior source_fingerprint onto the fused row" do
      prior.update!(source_fingerprint: "abc123")
      orchestrator.call
      expect(job.reload.latest_measurement.source_fingerprint).to be_nil
    end

    it "broadcasts fusion_complete to the [job, :fusion_status] stream" do
      expect { orchestrator.call }
        .to have_broadcasted_to("#{job.to_gid_param}:fusion_status").twice
    end

    it "never changes the job status from ready" do
      expect(job).not_to receive(:advance_to!)
      expect(job).not_to receive(:fail_with!)
      orchestrator.call
      expect(job.reload.status).to eq("ready")
    end

    it "chains the photo-overlay ProjectionJob (ADR-019)" do
      expect { orchestrator.call }.to have_enqueued_job(ProjectionJob).with(job.id)
    end
  end

  describe "ICP non-convergence (rmse >= 0.5)" do
    before do
      allow(sidecar).to receive(:fuse_capture)
        .and_return(fuse_response(rmse: 0.62, with_measurement: false))
    end

    it "creates no new measurement and appends an icp_alignment_failed warning" do
      expect { orchestrator.call }.not_to change { job.measurements.count }
      expect(prior.reload.warnings.join).to include("icp_alignment_failed")
      expect(prior.warnings.join).to include("0.62")
    end

    it "does NOT chain the projection job (no solved transform on a failed fusion)" do
      expect { orchestrator.call }.not_to have_enqueued_job(ProjectionJob)
    end

    it "is idempotent — a second run does not duplicate the warning" do
      orchestrator.call
      described_class.new(job, capture_session, sidecar: sidecar).call
      expect(prior.reload.warnings.count { |w| w.include?("icp_alignment_failed") }).to eq(1)
    end

    it "keeps the job status ready" do
      orchestrator.call
      expect(job.reload.status).to eq("ready")
    end
  end

  describe "null icp_rmse_m with a measurement present (malformed convergence)" do
    before do
      # A converged measurement MUST carry a finite rmse. A nil rmse alongside a
      # measurement is a failure — `.to_f` must not coerce nil to 0.0 and persist
      # an ungated fused row.
      allow(sidecar).to receive(:fuse_capture)
        .and_return(fuse_response(rmse: nil, with_measurement: true))
    end

    it "treats it as a failure: no new Measurement row, status stays ready" do
      expect { orchestrator.call }.not_to change { job.measurements.count }
      expect(job.reload.status).to eq("ready")
      expect(prior.reload.warnings.join).to include("icp_alignment_failed")
    end
  end

  describe "sidecar error (5xx / transport)" do
    before do
      allow(sidecar).to receive(:fuse_capture).and_raise(SidecarClient::Error.new("Sidecar returned 503"))
    end

    it "appends a fusion_failed warning and re-raises (for the job retry)" do
      expect { orchestrator.call }.to raise_error(SidecarClient::Error)
      expect(prior.reload.warnings.join).to include("fusion_failed")
    end

    it "creates no new measurement and leaves status ready" do
      expect { orchestrator.call rescue nil }.not_to change { job.measurements.count }
      expect(job.reload.status).to eq("ready")
    end
  end

  describe "LiDAR unavailable" do
    let(:prior_lidar) { { "status" => "LIDAR_MISSING" } }

    it "skips the sidecar entirely and appends an icp_skipped warning" do
      expect(sidecar).not_to receive(:fuse_capture)
      orchestrator.call
      expect(prior.reload.warnings.join).to include("icp_skipped: lidar_unavailable")
    end

    it "broadcasts fusion_failed reason and keeps status ready" do
      expect { orchestrator.call }
        .to have_broadcasted_to("#{job.to_gid_param}:fusion_status").once
      expect(job.reload.status).to eq("ready")
    end
  end
end
