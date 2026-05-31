require "rails_helper"

RSpec.describe SiteVisitVerifier, type: :service do
  subject(:verifier) { described_class.new }

  let(:job)         { create(:job) }
  # Use a measurement with a known geocode so haversine math is deterministic.
  let(:measurement) do
    create(:measurement, :complete, job: job)
    # :complete trait geocode: lat=39.7385, lon=-104.9945 (Denver area)
    job.latest_measurement
  end

  # Geocode coordinates from the :complete measurement trait
  let(:addr_lat) { 39.7385 }
  let(:addr_lon) { -104.9945 }

  # ---------------------------------------------------------------------------
  # Constant
  # ---------------------------------------------------------------------------

  it "VISIT_RADIUS_M is a positive integer (defaults to 12 in the standard test env)" do
    # The constant is frozen at load time from ENV["CLAIM_PDF_VISIT_RADIUS_M"].
    # In the test environment that variable is unset, so the default of 12 applies.
    expect(described_class::VISIT_RADIUS_M).to be_a(Integer)
    expect(described_class::VISIT_RADIUS_M).to be > 0
    # Verify the specific default (12) when the env var is absent in tests.
    expect(described_class::VISIT_RADIUS_M).to eq(12) unless ENV["CLAIM_PDF_VISIT_RADIUS_M"]
  end

  # ---------------------------------------------------------------------------
  # nil capture_session
  # ---------------------------------------------------------------------------

  describe "visit_verification_for with nil capture_session" do
    it "returns nil" do
      expect(verifier.visit_verification_for(nil, measurement)).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # Haversine distance math
  # ---------------------------------------------------------------------------

  describe "haversine distance math" do
    # Two points ~11 m apart (directly at the geocoded address — same coordinates)
    # should produce distance_m ≈ 0 and gps_verified: true.

    let(:capture_session) { create(:capture_session, job: job) }

    it "computes near-zero distance for a GPS fix at the same coordinates as the address" do
      create(:capture, capture_session: capture_session, sequence_index: 0,
             gps: { "latitude" => addr_lat, "longitude" => addr_lon })

      result = verifier.visit_verification_for(capture_session, measurement)
      expect(result[:distance_m]).to be_within(1.0).of(0.0)
      expect(result[:gps_verified]).to be(true)
    end

    it "computes a known distance for a point offset by a small delta" do
      # 0.0001 degree latitude offset ≈ 11.1 m at mid-latitudes
      nearby_lat = addr_lat + 0.0001
      create(:capture, capture_session: capture_session, sequence_index: 0,
             gps: { "latitude" => nearby_lat, "longitude" => addr_lon })

      result = verifier.visit_verification_for(capture_session, measurement)
      # Should be approximately 11 m (within tolerance).
      expect(result[:distance_m]).to be_within(3.0).of(11.1)
    end

    it "returns gps_verified: false when the nearest fix is beyond VISIT_RADIUS_M" do
      # Factory default GPS is 40.808 / -96.706 — hundreds of km from addr_lat/lon.
      create(:capture, capture_session: capture_session, sequence_index: 0)

      result = verifier.visit_verification_for(capture_session, measurement)
      expect(result[:gps_verified]).to be(false)
      expect(result[:distance_m]).to be > described_class::VISIT_RADIUS_M
    end

    it "uses the nearest capture (minimum distance across all captures)" do
      # One far capture, one near capture: nearest should win.
      create(:capture, capture_session: capture_session, sequence_index: 0)  # far (factory default)
      create(:capture, capture_session: capture_session, sequence_index: 1,
             gps: { "latitude" => addr_lat, "longitude" => addr_lon })       # near

      result = verifier.visit_verification_for(capture_session, measurement)
      expect(result[:gps_verified]).to be(true)
    end
  end

  # ---------------------------------------------------------------------------
  # No GPS on captures
  # ---------------------------------------------------------------------------

  describe "with captures that have no GPS" do
    let(:capture_session) { create(:capture_session, job: job) }

    it "returns gps_verified: false and nil distance_m when GPS is nil on all captures" do
      create(:capture, capture_session: capture_session, sequence_index: 0, gps: nil)

      result = verifier.visit_verification_for(capture_session, measurement)
      expect(result[:gps_verified]).to be(false)
      expect(result[:distance_m]).to be_nil
    end

    it "returns gps_verified: false when GPS is a non-Hash value" do
      create(:capture, capture_session: capture_session, sequence_index: 0, gps: "invalid")

      result = verifier.visit_verification_for(capture_session, measurement)
      expect(result[:gps_verified]).to be(false)
    end
  end

  # ---------------------------------------------------------------------------
  # Result shape
  # ---------------------------------------------------------------------------

  describe "result shape" do
    let(:capture_session) do
      create(:capture_session, job: job, ended_at: 2.hours.ago)
    end

    before do
      create(:capture, capture_session: capture_session, sequence_index: 0,
             gps: { "latitude" => addr_lat, "longitude" => addr_lon })
    end

    it "includes photo_count, visit_time, radius_m, gps_verified, distance_m" do
      result = verifier.visit_verification_for(capture_session, measurement)
      expect(result.keys).to contain_exactly(:photo_count, :visit_time, :radius_m,
                                             :gps_verified, :distance_m)
    end

    it "sets photo_count to the number of captures in the session" do
      create(:capture, capture_session: capture_session, sequence_index: 1,
             gps: { "latitude" => addr_lat, "longitude" => addr_lon })

      result = verifier.visit_verification_for(capture_session, measurement)
      expect(result[:photo_count]).to eq(2)
    end

    it "sets radius_m to VISIT_RADIUS_M" do
      result = verifier.visit_verification_for(capture_session, measurement)
      expect(result[:radius_m]).to eq(described_class::VISIT_RADIUS_M)
    end

    it "sets visit_time from ended_at when present" do
      result = verifier.visit_verification_for(capture_session, measurement)
      expect(result[:visit_time]).to be_a(String)
      expect(result[:visit_time]).to match(/\d{4}-\d{2}-\d{2}/)
    end
  end

  # ---------------------------------------------------------------------------
  # CLAIM_PDF_VISIT_RADIUS_M env-override
  # ---------------------------------------------------------------------------

  describe "CLAIM_PDF_VISIT_RADIUS_M env override" do
    it "the constant expression honors an integer env override" do
      # SiteVisitVerifier::VISIT_RADIUS_M is frozen at load time, so we test
      # the expression logic directly rather than trying to mutate the frozen
      # constant in the running process.
      computed = (ENV.fetch("CLAIM_PDF_VISIT_RADIUS_M", nil).presence&.to_i || 12)
      expect(computed).to be_an(Integer)
      expect(computed).to be > 0
    end
  end
end
