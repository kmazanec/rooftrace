require "rails_helper"

RSpec.describe Capture, type: :model do
  it "belongs to a capture_session" do
    assoc = described_class.reflect_on_association(:capture_session)
    expect(assoc.macro).to eq(:belongs_to)
  end

  it "requires a sequence_index" do
    capture = build(:capture, sequence_index: nil)
    expect(capture).not_to be_valid
    expect(capture.errors[:sequence_index]).to be_present
  end

  it "is valid with a capture_session and sequence_index" do
    expect(build(:capture)).to be_valid
  end
end
