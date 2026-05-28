require "rails_helper"

RSpec.describe TokenGenerator do
  describe ".token" do
    it "is exactly 32 characters" do
      expect(described_class.token.length).to eq(32)
    end

    it "uses only the RFC 4648 base32 alphabet" do
      expect(described_class.token).to match(/\A[A-Z2-7]{32}\z/)
    end

    it "is unique across a batch of 10k (entropy/collision check)" do
      batch = Array.new(10_000) { described_class.token }
      expect(batch.uniq.length).to eq(10_000)
    end
  end
end
