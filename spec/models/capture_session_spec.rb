require "rails_helper"

RSpec.describe CaptureSession, type: :model do
  it "belongs to a job" do
    assoc = described_class.reflect_on_association(:job)
    expect(assoc.macro).to eq(:belongs_to)
  end

  it "has many captures, destroyed with the session" do
    assoc = described_class.reflect_on_association(:captures)
    expect(assoc.macro).to eq(:has_many)
    expect(assoc.options[:dependent]).to eq(:destroy)
  end

  it "requires session_id, manifest_version, and a job" do
    cs = described_class.new
    expect(cs).not_to be_valid
    expect(cs.errors[:session_id]).to be_present
    expect(cs.errors[:manifest_version]).to be_present
    expect(cs.errors[:job]).to be_present
  end

  it "enforces session_id uniqueness" do
    existing = create(:capture_session)
    dup = build(:capture_session, session_id: existing.session_id)
    expect(dup).not_to be_valid
    expect(dup.errors[:session_id]).to be_present
  end

  it "destroys its captures when destroyed" do
    cs = create(:capture_session)
    create(:capture, capture_session: cs)
    expect { cs.destroy }.to change(Capture, :count).by(-1)
  end
end
