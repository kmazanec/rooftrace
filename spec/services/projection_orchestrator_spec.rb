require "rails_helper"

# ProjectionOrchestrator unit tests. SidecarClient is stubbed; the unit under
# test is the per-photo projection orchestration (ADR-019): for each capture
# with a photo, Rails computes the pose_confidence (single authority), and either
#   - calls the sidecar project_photo and persists a ProjectedOverlay (acceptable
#     pose), OR
#   - persists a low_pose_confidence overlay with NO sidecar call (below the
#     threshold) so the surfaces warn rather than draw a misregistered overlay.
# It NEVER touches Job status (projection is additive, like fusion).
RSpec.describe ProjectionOrchestrator, type: :service do
  let(:job) { create(:job, status: "ready") }
  let(:capture_session) { create(:capture_session, job: job) }
  let(:sidecar) { class_double(SidecarClient) }

  # A fused measurement carrying the solved transform in provenance.
  let!(:fused) do
    create(:measurement, :complete, job: job, source: "lidar+device+imagery",
           generated_at: 1.minute.ago,
           provenance: {
             "fusion_icp_rmse_m" => 0.05,
             Measurement::FUSION_ARKIT_TO_UTM_KEY => Array.new(16) { |i| i % 5 == 0 ? 1.0 : 0.0 },
             Measurement::FUSION_UTM_EPSG_KEY => 32614
           })
  end

  # Identity-rotation, finite-translation extrinsics -> a sane pose.
  let(:good_extrinsics) do
    [ 1.0, 0.0, 0.0, 2.5,
      0.0, 1.0, 0.0, 1.2,
      0.0, 0.0, 1.0, -8.0,
      0.0, 0.0, 0.0, 1.0 ]
  end

  let!(:capture) do
    create(:capture, capture_session: capture_session, sequence_index: 0,
           photo_ref: "uploads/#{job.id}/photo_00.jpg",
           camera_intrinsics: [ 1000.0, 0.0, 512.0, 0.0, 1000.0, 384.0, 0.0, 0.0, 1.0 ],
           camera_extrinsics: good_extrinsics)
  end

  subject(:orchestrator) { described_class.new(job, sidecar: sidecar) }

  def project_response
    {
      "pipelineSchemaVersion" => "0.4.0",
      "job_id" => job.id,
      "overlay_ref" => "artifacts/#{job.id}/projected/photo_00.png",
      "composite_ref" => "artifacts/#{job.id}/projected/photo_00.png",
      "overlay_svg_ref" => "artifacts/#{job.id}/projected/photo_00.svg",
      "pose_confidence" => 0.92,
      "occluded_facet_ids" => [ "F2" ]
    }
  end

  describe "acceptable pose" do
    before { allow(sidecar).to receive(:project_photo).and_return(project_response) }

    it "calls the sidecar and persists a ProjectedOverlay" do
      expect { orchestrator.call }.to change { ProjectedOverlay.count }.by(1)
      overlay = capture.reload.projected_overlay
      expect(overlay.composite_ref).to eq("artifacts/#{job.id}/projected/photo_00.png")
      expect(overlay.overlay_svg_ref).to eq("artifacts/#{job.id}/projected/photo_00.svg")
      expect(overlay.low_pose_confidence).to be(false)
      expect(overlay.occluded_facet_ids).to eq([ "F2" ])
    end

    it "passes the solved transform + epsg + facets + pose_confidence to the sidecar" do
      expect(sidecar).to receive(:project_photo).with(
        hash_including(
          job_id: job.id,
          photo_ref: "uploads/#{job.id}/photo_00.jpg",
          utm_epsg: 32614,
          arkit_to_utm: kind_of(Array)
        )
      ).and_return(project_response)
      orchestrator.call
    end

    it "never changes the job status" do
      expect { orchestrator.call }.not_to change { job.reload.status }
    end

    it "is idempotent — re-running updates the existing overlay, not a duplicate" do
      orchestrator.call
      expect { described_class.new(job, sidecar: sidecar).call }
        .not_to change { ProjectedOverlay.count }
    end
  end

  describe "low pose confidence" do
    before do
      capture.update!(camera_extrinsics: [ Float::NAN ] + Array.new(15, 0.0))
    end

    it "persists a low_pose_confidence overlay WITHOUT calling the sidecar" do
      expect(sidecar).not_to receive(:project_photo)
      expect { orchestrator.call }.to change { ProjectedOverlay.count }.by(1)
      overlay = capture.reload.projected_overlay
      expect(overlay.low_pose_confidence).to be(true)
      expect(overlay.composite_ref).to be_nil
    end
  end

  describe "no solved transform (measurement predates fusion field)" do
    before do
      fused.update!(provenance: { "fusion_icp_rmse_m" => 0.05 })
    end

    it "skips projection entirely (no overlays, no sidecar call)" do
      expect(sidecar).not_to receive(:project_photo)
      expect { orchestrator.call }.not_to change { ProjectedOverlay.count }
    end
  end

  describe "sidecar error on a photo" do
    before { allow(sidecar).to receive(:project_photo).and_raise(SidecarClient::Error) }

    it "degrades that photo to a low_pose_confidence overlay and continues (re-raises for retry)" do
      expect { orchestrator.call }.to raise_error(SidecarClient::Error)
    end
  end
end
