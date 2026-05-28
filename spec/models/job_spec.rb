require "rails_helper"

RSpec.describe Job do
  describe "capture token assignment on create" do
    let(:job) { create(:job) }

    it "assigns a 32-char base32 capture token" do
      expect(job.capture_token).to match(/\A[A-Z2-7]{32}\z/)
    end

    it "defaults the expiry to 24h after creation" do
      expect(job.capture_token_expires_at).to be_within(5.seconds).of(Job::CAPTURE_TOKEN_TTL.from_now)
    end

    it "gives each job a distinct token" do
      expect(create(:job).capture_token).not_to eq(job.capture_token)
    end

    it "regenerates the token and retries on a unique-index collision" do
      existing = create(:job)
      # Force the first generated token to collide with an existing row, then a
      # fresh token on retry. The create must succeed, not raise RecordNotUnique.
      # The retry token is generated at runtime (a real unique token) rather than
      # a hardcoded literal, so it can't collide with a leaked/committed row in a
      # dirty DB and make this test spuriously red.
      retry_token = TokenGenerator.token
      allow(TokenGenerator).to receive(:token).and_return(existing.capture_token, retry_token)
      expect { create(:job) }.not_to raise_error
      expect(Job.last.capture_token).to eq(retry_token)
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
