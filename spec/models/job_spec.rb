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

  describe "pipeline status (C0.2)" do
    let(:job) { create(:job) }

    it "starts pending" do
      expect(job.status).to eq("pending")
      expect(job).to be_pending
    end

    it "declares exactly the ordered pipeline status set" do
      expect(described_class.statuses.keys).to eq(
        %w[
          pending resolving_address fetching_imagery fetching_lidar
          refining_outline detecting_features fitting_planes ready failed
        ]
      )
    end

    describe "#advance_to!" do
      it "persists the new status" do
        job.advance_to!(:resolving_address)
        expect(job.reload.status).to eq("resolving_address")
      end

      it "accepts a string status" do
        job.advance_to!("fetching_lidar")
        expect(job.reload.status).to eq("fetching_lidar")
      end

      it "broadcasts a Turbo Stream replace to the job's own status stream" do
        # turbo-rails broadcasts to `stream_name_from([job, :status])`, i.e.
        # "<job gid param>:status" (no `turbo:streams:` channel prefix), so we
        # assert against that raw stream rather than `.from_channel(...)`, whose
        # `broadcasting_for` would add the prefix turbo doesn't use. This is the
        # exact stream the view subscribes to via `turbo_stream_from(job, :status)`.
        expect { job.advance_to!(:refining_outline) }
          .to have_broadcasted_to("#{job.to_gid_param}:status")
      end

      it "raises ArgumentError on an unknown status (no silent no-op)" do
        expect { job.advance_to!(:bogus) }.to raise_error(ArgumentError)
        expect(job.reload.status).to eq("pending")
      end

      it "raises rather than resurrecting a failed (terminal) job" do
        job.fail_with!("boom")
        expect { job.advance_to!(:resolving_address) }.to raise_error(ArgumentError)
        expect(job.reload.status).to eq("failed")
      end

      it "raises rather than re-advancing a ready (terminal) job" do
        job.update!(status: "ready")
        expect { job.advance_to!(:resolving_address) }.to raise_error(ArgumentError)
        expect(job.reload.status).to eq("ready")
      end
    end

    describe "#fail_with!" do
      it "moves the job to failed and records the message" do
        job.fail_with!("geocode failed: address not found")
        job.reload
        expect(job).to be_failed
        expect(job.last_error).to eq("geocode failed: address not found")
      end

      it "broadcasts to the job's status stream" do
        expect { job.fail_with!("boom") }
          .to have_broadcasted_to("#{job.to_gid_param}:status")
      end
    end

    describe "#terminal?" do
      it "is true only for ready or failed" do
        expect(job).not_to be_terminal
        job.advance_to!(:ready)
        expect(job).to be_terminal
        job.update!(status: "failed")
        expect(job).to be_terminal
        job.update!(status: "fitting_planes")
        expect(job).not_to be_terminal
      end
    end
  end

  describe "measurements association" do
    let(:job) { create(:job) }

    it "has many measurements and destroys them with the job" do
      create(:measurement, job: job)
      expect { job.destroy }.to change(Measurement, :count).by(-1)
    end

    it "#latest_measurement returns the most recent by generated_at" do
      create(:measurement, job: job, generated_at: 2.hours.ago)
      newest = create(:measurement, job: job, generated_at: 1.minute.ago)
      create(:measurement, job: job, generated_at: 1.hour.ago)
      expect(job.latest_measurement).to eq(newest)
    end
  end
end
