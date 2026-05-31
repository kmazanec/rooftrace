require "rails_helper"

RSpec.describe MeasurementIdempotencyCache, type: :service do
  let(:job)    { create(:job, address: "1600 Pennsylvania Ave NW, Washington, DC 20500") }
  let(:logger) { instance_double(ActiveSupport::Logger, info: nil) }

  subject(:cache) { described_class.new(job, logger: logger) }

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def measurement_with_fingerprint(fp, generated_at: Time.current)
    create(:measurement, job: job, generated_at: generated_at,
           source_fingerprint: fp)
  end

  # ---------------------------------------------------------------------------
  # IDEMPOTENCY_WINDOW constant
  # ---------------------------------------------------------------------------

  it "IDEMPOTENCY_WINDOW is 1 hour" do
    expect(described_class::IDEMPOTENCY_WINDOW).to eq(1.hour)
  end

  # ---------------------------------------------------------------------------
  # fingerprint
  # ---------------------------------------------------------------------------

  describe "#fingerprint" do
    it "returns the same value across multiple calls (memoized)" do
      first  = cache.fingerprint
      second = cache.fingerprint
      expect(first).to eq(second)
    end

    it "is a non-empty hex string" do
      expect(cache.fingerprint).to match(/\A[0-9a-f]{64}\z/)
    end

    it "differs for a different address" do
      other_job = create(:job, address: "742 Evergreen Terrace, Springfield")
      other_cache = described_class.new(other_job, logger: logger)
      expect(cache.fingerprint).not_to eq(other_cache.fingerprint)
    end

    it "differs for a different polygon_selection on the same address" do
      # fingerprint memoizes on first call, so capture each value BEFORE mutating
      # the shared job to the next selection (otherwise both caches read the final
      # polygon_selection off the same record and collide).
      job.update!(polygon_selection: 1)
      fingerprint_sel1 = described_class.new(job, logger: logger).fingerprint

      job.update!(polygon_selection: 2)
      fingerprint_sel2 = described_class.new(job, logger: logger).fingerprint

      expect(fingerprint_sel1).not_to eq(fingerprint_sel2)
    end

    it "is unambiguous even when address and selection share characters" do
      # A naive single-char join could make ("ab", "1") == ("a", "b1") etc.
      job_a = build(:job, address: "ab",  polygon_selection: 1)
      job_b = build(:job, address: "a",   polygon_selection: 0)
      cache_a = described_class.new(job_a, logger: logger)
      cache_b = described_class.new(job_b, logger: logger)
      expect(cache_a.fingerprint).not_to eq(cache_b.fingerprint)
    end
  end

  # ---------------------------------------------------------------------------
  # cached_measurement — no match cases
  # ---------------------------------------------------------------------------

  describe "#cached_measurement" do
    context "when there is no measurement at all" do
      it "returns nil" do
        expect(cache.cached_measurement).to be_nil
      end
    end

    context "when the measurement is older than the idempotency window" do
      it "returns nil" do
        m = measurement_with_fingerprint(cache.fingerprint,
                                         generated_at: 2.hours.ago)
        expect(cache.cached_measurement).to be_nil
      end
    end

    context "when the measurement fingerprint does not match (address changed)" do
      it "returns nil" do
        measurement_with_fingerprint("stale_fingerprint_abc123")
        expect(cache.cached_measurement).to be_nil
      end
    end

    context "when generated_at is nil" do
      it "returns nil" do
        m = create(:measurement, job: job, generated_at: nil,
                   source_fingerprint: cache.fingerprint)
        expect(cache.cached_measurement).to be_nil
      end
    end
  end

  # ---------------------------------------------------------------------------
  # cached_measurement — cache hit cases
  # ---------------------------------------------------------------------------

  describe "#cached_measurement (hit)" do
    let!(:fresh) do
      measurement_with_fingerprint(cache.fingerprint, generated_at: 30.minutes.ago)
    end

    it "returns the fresh matching measurement" do
      expect(cache.cached_measurement).to eq(fresh)
    end

    it "logs a cache-hit message" do
      cache.cached_measurement
      expect(logger).to have_received(:info).with(a_string_including("reusing measurement"))
    end

    context "when the job is already :ready" do
      before { job.update_column(:status, "ready") }

      it "returns the measurement without calling advance_to!" do
        expect(job).not_to receive(:advance_to!)
        result = cache.cached_measurement
        expect(result).to eq(fresh)
        expect(job.reload.status).to eq("ready")
      end
    end

    context "stuck-job advance path (non-terminal, non-ready)" do
      # Simulate a job that was left mid-pipeline after a crash: it has a valid
      # recent measurement (the fingerprint matches) but its status is still an
      # in-progress stage.
      before { job.update_column(:status, "fitting_planes") }

      it "advances the job to :ready" do
        cache.cached_measurement
        expect(job.reload.status).to eq("ready")
      end

      it "returns the fresh measurement" do
        expect(cache.cached_measurement).to eq(fresh)
      end
    end

    context "failed job (terminal)" do
      before { job.update_column(:status, "failed") }

      it "does NOT call advance_to! (terminal jobs cannot be advanced)" do
        expect(job).not_to receive(:advance_to!)
        cache.cached_measurement
      end

      it "still returns the measurement (the caller decides what to do)" do
        expect(cache.cached_measurement).to eq(fresh)
      end
    end
  end
end
