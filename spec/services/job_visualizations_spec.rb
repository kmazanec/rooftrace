require "rails_helper"

# JobVisualizations builds the on-site-visualization array for the JSON export
# (json_export 1.1.0), with SIGNED artifact URLs, ordered pose_confidence DESC.
RSpec.describe JobVisualizations do
  let(:job) { create(:job) }
  let(:session) { create(:capture_session, job: job) }

  before do
    allow(ArtifactUrlMinter).to receive(:call) { |object_key:, **| "https://signed/#{object_key}" }
  end

  it "returns [] for a job with no overlays" do
    expect(described_class.for(job)).to eq([])
  end

  it "emits one signed entry per overlay, ordered most-pose-confident first" do
    low = create(:capture, capture_session: session, sequence_index: 0)
    high = create(:capture, capture_session: session, sequence_index: 1)
    create(:projected_overlay, capture: low, composite_ref: "artifacts/j/projected/0.png",
           overlay_svg_ref: "artifacts/j/projected/0.svg", pose_confidence: 0.5)
    create(:projected_overlay, capture: high, composite_ref: "artifacts/j/projected/1.png",
           overlay_svg_ref: "artifacts/j/projected/1.svg", pose_confidence: 0.9)

    result = described_class.for(job)
    expect(result.length).to eq(2)
    expect(result.first["pose_confidence"]).to eq(0.9)
    expect(result.first["composite_url"]).to eq("https://signed/artifacts/j/projected/1.png")
    expect(result.first["overlay_svg_url"]).to eq("https://signed/artifacts/j/projected/1.svg")
    expect(result.first["photo_url"]).to be_nil
  end

  it "skips a low_pose_confidence overlay with no artifacts" do
    cap = create(:capture, capture_session: session, sequence_index: 0)
    create(:projected_overlay, capture: cap, composite_ref: nil, overlay_svg_ref: nil,
           pose_confidence: 0.2, low_pose_confidence: true)
    expect(described_class.for(job)).to eq([])
  end

  it "nils a URL whose mint fails but keeps the entry when the other survives" do
    cap = create(:capture, capture_session: session, sequence_index: 0)
    create(:projected_overlay, capture: cap, composite_ref: "artifacts/j/projected/0.png",
           overlay_svg_ref: "artifacts/j/projected/0.svg", pose_confidence: 0.7)
    allow(ArtifactUrlMinter).to receive(:call).with(object_key: "artifacts/j/projected/0.png")
      .and_raise(ArtifactUrlMinter::Error)
    allow(ArtifactUrlMinter).to receive(:call).with(object_key: "artifacts/j/projected/0.svg")
      .and_return("https://signed/svg")

    result = described_class.for(job)
    expect(result.length).to eq(1)
    expect(result.first["composite_url"]).to be_nil
    expect(result.first["overlay_svg_url"]).to eq("https://signed/svg")
  end
end
