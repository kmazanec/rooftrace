require "rails_helper"

RSpec.describe AppToken, type: :model do
  describe "creation" do
    it "assigns an opaque token and default expiry" do
      now = Time.current
      app_token = described_class.create!

      expect(app_token.token).to be_present
      expect(app_token.token.length).to eq(32)
      expect(app_token.expires_at).to be_between(now + AppToken::TTL, Time.current + AppToken::TTL)
    end

    it "has a unique database index on token" do
      indexes = ActiveRecord::Base.connection.indexes(:app_tokens)
      expect(indexes).to include(have_attributes(columns: [ "token" ], unique: true))
    end

    it "rejects duplicate tokens at the database boundary" do
      token = SecureRandom.base58(32)
      expires_at = AppToken::TTL.from_now
      described_class.insert!({ token: token, expires_at: expires_at, created_at: Time.current, updated_at: Time.current })

      expect {
        described_class.insert!({ token: token, expires_at: expires_at, created_at: Time.current, updated_at: Time.current })
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe ".authenticate" do
    it "returns the token record for a valid raw token" do
      app_token = described_class.create!

      expect(described_class.authenticate(app_token.token)).to eq(app_token)
    end

    it "returns nil for blank, unknown, and expired tokens" do
      expired = described_class.create!(expires_at: 1.second.ago)

      expect(described_class.authenticate(nil)).to be_nil
      expect(described_class.authenticate("")).to be_nil
      expect(described_class.authenticate("missing")).to be_nil
      expect(described_class.authenticate(expired.token)).to be_nil
    end
  end

  describe "#expired?" do
    it "treats nil and past expiries as expired" do
      expect(described_class.new(expires_at: nil)).to be_expired
      expect(described_class.new(expires_at: 1.second.ago)).to be_expired
      expect(described_class.new(expires_at: 1.second.from_now)).not_to be_expired
    end
  end
end
