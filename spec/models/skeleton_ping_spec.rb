require "rails_helper"

RSpec.describe SkeletonPing, type: :model do
  it "persists and round-trips a record" do
    ping = create(:skeleton_ping)
    expect(ping).to be_persisted
    expect(SkeletonPing.find(ping.id).job_id).to eq(ping.job_id)
  end

  it "requires job_id" do
    ping = build(:skeleton_ping, job_id: nil)
    expect(ping).not_to be_valid
    expect(ping.errors[:job_id]).to be_present
  end

  it "requires non-negative integer rtt_ms" do
    ping = build(:skeleton_ping, rtt_ms: -1)
    expect(ping).not_to be_valid
    expect(ping.errors[:rtt_ms]).to be_present
  end

  it "stores jsonb payload as a hash" do
    payload = { "echo_payload" => "hi", "sidecar_version" => "0.1.0" }
    ping = create(:skeleton_ping, sidecar_payload: payload)
    expect(SkeletonPing.find(ping.id).sidecar_payload).to eq(payload)
  end
end
