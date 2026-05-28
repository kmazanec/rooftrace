require "rails_helper"

RSpec.describe Job do
  describe "capture token assignment on create" do
    let(:job) { create(:job) }

    it "assigns an unguessable base58 capture token (has_secure_token, 32 chars)" do
      # SecureRandom.base58 alphabet: 1-9 + A-H,J-N,P-Z + a-k,m-z (no 0 O I l).
      expect(job.capture_token).to match(%r{\A[1-9A-HJ-NP-Za-km-z]{32}\z})
    end

    it "defaults the expiry to 24h after creation" do
      expect(job.capture_token_expires_at).to be_within(5.seconds).of(Job::CAPTURE_TOKEN_TTL.from_now)
    end

    it "gives each job a distinct token" do
      expect(create(:job).capture_token).not_to eq(job.capture_token)
    end

    it "enforces capture_token uniqueness at the database (unique index)" do
      # save!(validate: false) skips the create callbacks, so set the NOT NULL
      # expiry explicitly; we're exercising the DB unique index on the token.
      dup = build(:job, capture_token: job.capture_token, capture_token_expires_at: 1.day.from_now)
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe ".authenticate_capture_token" do
    let(:job) { create(:job) }

    it "resolves a job by a live token" do
      expect(described_class.authenticate_capture_token(job.capture_token)).to eq(job)
    end

    it "returns nil for an unknown token" do
      expect(described_class.authenticate_capture_token("X" * 32)).to be_nil
    end

    it "returns nil for a blank token" do
      expect(described_class.authenticate_capture_token(nil)).to be_nil
      expect(described_class.authenticate_capture_token("")).to be_nil
    end

    it "returns nil for an expired token" do
      job.update_column(:capture_token_expires_at, 1.minute.ago)
      expect(described_class.authenticate_capture_token(job.capture_token)).to be_nil
    end
  end
end
