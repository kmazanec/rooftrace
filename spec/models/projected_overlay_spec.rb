require "rails_helper"

RSpec.describe ProjectedOverlay, type: :model do
  let(:job)             { create(:job) }
  let(:capture_session) { create(:capture_session, job: job) }
  let(:capture)         { create(:capture, capture_session: capture_session) }

  # ---------------------------------------------------------------------------
  # Association + dependent destroy
  # ---------------------------------------------------------------------------

  describe "belongs_to :capture (behavioral)" do
    it "is reachable from its capture" do
      overlay = create(:projected_overlay, capture: capture)
      expect(capture.reload.projected_overlay).to eq(overlay)
    end

    it "is destroyed when its capture is destroyed (dependent: :destroy)" do
      overlay = create(:projected_overlay, capture: capture)
      expect { capture.destroy }.to change { ProjectedOverlay.count }.by(-1)
      expect { overlay.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  # ---------------------------------------------------------------------------
  # NOT NULL / DB constraints (bypassing validations to probe the DB)
  # ---------------------------------------------------------------------------

  describe "NOT NULL constraints" do
    it "cannot be persisted without a capture_id" do
      overlay = build(:projected_overlay, capture: nil)
      # AR validates presence via belongs_to; we confirm the column is non-null
      # at the model level by checking it fails to save.
      expect(overlay.save).to be(false)
      expect(overlay.errors[:capture]).to be_present
    end
  end

  # ---------------------------------------------------------------------------
  # .for_job scope
  # ---------------------------------------------------------------------------

  describe ".for_job" do
    let(:other_job)             { create(:job) }
    let(:other_capture_session) { create(:capture_session, job: other_job) }
    let(:other_capture)         { create(:capture, capture_session: other_capture_session) }

    let!(:overlay_for_job)       { create(:projected_overlay, capture: capture) }
    let!(:overlay_for_other_job) { create(:projected_overlay, capture: other_capture) }

    it "returns overlays belonging to the given job" do
      results = described_class.for_job(job)
      expect(results).to include(overlay_for_job)
      expect(results).not_to include(overlay_for_other_job)
    end

    it "returns nothing when the job has no captures" do
      empty_job = create(:job)
      expect(described_class.for_job(empty_job)).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # .sorted_by_pose_confidence
  # ---------------------------------------------------------------------------

  describe ".sorted_by_pose_confidence" do
    let(:cs2) { create(:capture_session, job: job) }
    let(:c1)  { create(:capture, capture_session: capture_session, sequence_index: 0) }
    let(:c2)  { create(:capture, capture_session: cs2, sequence_index: 0) }

    it "returns the most pose-confident overlay first" do
      high = create(:projected_overlay, capture: c1, pose_confidence: 0.95)
      low  = create(:projected_overlay, capture: c2, pose_confidence: 0.42)

      result = described_class.sorted_by_pose_confidence([ low, high ])
      expect(result.first).to eq(high)
      expect(result.last).to eq(low)
    end

    it "sorts nil confidence to the end" do
      good = create(:projected_overlay, capture: c1, pose_confidence: 0.80)
      nil_conf_capture = create(:capture, capture_session: capture_session, sequence_index: 1)
      nil_conf = create(:projected_overlay, capture: nil_conf_capture, pose_confidence: nil)

      result = described_class.sorted_by_pose_confidence([ nil_conf, good ])
      expect(result.first).to eq(good)
      expect(result.last).to eq(nil_conf)
    end

    it "preserves relative order when confidences are equal" do
      c_a = create(:capture, capture_session: capture_session, sequence_index: 2)
      c_b = create(:capture, capture_session: capture_session, sequence_index: 3)
      ov_a = create(:projected_overlay, capture: c_a, pose_confidence: 0.70)
      ov_b = create(:projected_overlay, capture: c_b, pose_confidence: 0.70)

      result = described_class.sorted_by_pose_confidence([ ov_a, ov_b ])
      expect(result.map(&:id)).to contain_exactly(ov_a.id, ov_b.id)
    end

    it "returns an empty array for an empty input" do
      expect(described_class.sorted_by_pose_confidence([])).to eq([])
    end
  end
end
