require "rails_helper"

# Rails is the SINGLE authority on per-photo pose confidence (ADR-019): it derives
# a [0,1] score from the session-level ICP residual (icp_rmse_m) and a per-photo
# extrinsics sanity check (finite, orthonormal-ish rotation, plausible
# translation). The sidecar may only NARROW the value, never raise it. The
# threshold below which no composite is generated is PROJECTION_POSE_CONFIDENCE_MIN
# (default 0.7).
RSpec.describe ProjectionPoseConfidence do
  # A well-formed identity-rotation extrinsic (orthonormal R, finite t).
  def good_extrinsics
    [ 1.0, 0.0, 0.0, 2.5,
      0.0, 1.0, 0.0, 1.2,
      0.0, 0.0, 1.0, -8.0,
      0.0, 0.0, 0.0, 1.0 ]
  end

  describe ".score" do
    it "returns a high score for a tight ICP fit and a sane pose" do
      score = described_class.score(icp_rmse_m: 0.05, extrinsics: good_extrinsics)
      expect(score).to be > 0.7
      expect(score).to be <= 1.0
    end

    it "is monotonic-decreasing in icp_rmse_m" do
      tight = described_class.score(icp_rmse_m: 0.05, extrinsics: good_extrinsics)
      loose = described_class.score(icp_rmse_m: 0.30, extrinsics: good_extrinsics)
      expect(tight).to be > loose
    end

    it "drops to zero for a non-finite extrinsic" do
      bad = good_extrinsics
      bad[3] = Float::NAN
      expect(described_class.score(icp_rmse_m: 0.05, extrinsics: bad)).to eq(0.0)
    end

    it "drops to zero for a non-orthonormal rotation block" do
      # Scale the rotation 3x — no longer orthonormal.
      bad = [ 3.0, 0.0, 0.0, 0.0,
              0.0, 3.0, 0.0, 0.0,
              0.0, 0.0, 3.0, 0.0,
              0.0, 0.0, 0.0, 1.0 ]
      expect(described_class.score(icp_rmse_m: 0.05, extrinsics: bad)).to eq(0.0)
    end

    it "drops to zero for an implausibly large translation" do
      bad = good_extrinsics
      bad[7] = 100_000.0 # 100 km from the session origin
      expect(described_class.score(icp_rmse_m: 0.05, extrinsics: bad)).to eq(0.0)
    end

    it "returns zero when icp_rmse_m is nil (no converged fusion)" do
      expect(described_class.score(icp_rmse_m: nil, extrinsics: good_extrinsics)).to eq(0.0)
    end

    it "clamps to [0,1]" do
      score = described_class.score(icp_rmse_m: 0.0, extrinsics: good_extrinsics)
      expect(score).to be <= 1.0
      expect(score).to be >= 0.0
    end

    it "rejects a malformed (non-16) extrinsic with zero" do
      expect(described_class.score(icp_rmse_m: 0.05, extrinsics: [ 1.0, 2.0 ])).to eq(0.0)
    end
  end

  describe ".threshold" do
    it "defaults to 0.7" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("PROJECTION_POSE_CONFIDENCE_MIN").and_return(nil)
      expect(described_class.threshold).to eq(0.7)
    end

    it "reads PROJECTION_POSE_CONFIDENCE_MIN when set" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("PROJECTION_POSE_CONFIDENCE_MIN").and_return("0.85")
      expect(described_class.threshold).to eq(0.85)
    end
  end

  describe ".acceptable?" do
    it "is true at/above the threshold and false below" do
      allow(described_class).to receive(:threshold).and_return(0.7)
      expect(described_class.acceptable?(0.7)).to be(true)
      expect(described_class.acceptable?(0.69)).to be(false)
      expect(described_class.acceptable?(nil)).to be(false)
    end
  end
end
