require "rails_helper"

# Claim-defensibility PDF enhancement specs (ADR-018).
#
# Tests:
#   - Conditional rendering: visit + evidence blocks present iff a completed
#     CaptureSession exists, absent without placeholder when none.
#   - Evidence seam: thumbnails ordered by sequence_index; degrades to [] on
#     SidecarClient::Error. (Composite preference is exercised in
#     report_pdf_spec.rb; with no ProjectedOverlay rows the builder falls
#     through to sidecar thumbnails, which is what this spec drives.)
#   - HONEST GPS verification: the "GPS-verified within N m of the geocoded
#     address" claim is asserted ONLY when a capture's recorded GPS fix is
#     actually within CLAIM_PDF_VISIT_RADIUS_M of the address; otherwise the
#     wording is softened and GPS verification is NOT asserted.
#   - Methodology text generated from provenance in the HTML.
#   - Reproducibility: two renders of the same job produce the same HTML
#     (modulo generated_at).
RSpec.describe ReportPdf, type: :service do
  let(:job)          { create(:job) }
  let!(:measurement) { create(:measurement, :complete, job: job) }

  # The :complete measurement geocode coordinates (geocoded address).
  let(:addr_lat) { 39.7385 }
  let(:addr_lon) { -104.9945 }

  let(:image_ref)    { "artifacts/#{job.id}/images/map-abc123.png" }
  let(:pdf_bytes)    { "%PDF-1.4\nfake pdf bytes\n%%EOF" }
  let(:store)        { instance_double("ArtifactStore") }
  let(:grover_double) { instance_double(Grover, to_pdf: pdf_bytes) }

  before do
    allow(SidecarClient).to receive(:render_images).and_return({ "image_ref" => image_ref })
    allow(ArtifactUrlMinter).to receive(:call) do |object_key:, **|
      "https://spaces.example.com/#{object_key}?signed=1"
    end
    allow(Grover).to receive(:new).and_return(grover_double)
    allow(store).to receive(:head).and_return(nil)
    allow(store).to receive(:put).and_return(true)
    # Default: no evidence thumbnails needed (no capture session).
    allow(SidecarClient).to receive(:render_evidence_thumbnails).and_call_original
  end

  def capture_html
    captured = nil
    allow(Grover).to receive(:new) do |html, *|
      captured = html
      grover_double
    end
    described_class.new(job, store: store).render
    captured
  end

  # ---------------------------------------------------------------------------
  # Conditional rendering: no CaptureSession
  # ---------------------------------------------------------------------------

  describe "without a CaptureSession" do
    it "omits the site-visit block entirely (no placeholder)" do
      html = capture_html
      expect(html).not_to include("Site Visit")
      expect(html).not_to include("report-visit-verification")
    end

    it "omits the evidence photos block entirely (no placeholder)" do
      html = capture_html
      expect(html).not_to include("On-site photos")
      expect(html).not_to include("report-evidence-grid")
    end

    it "renders the methodology section (from provenance)" do
      html = capture_html
      # The methodology section should appear — even without a capture session
      # the measurement has provenance data in the :complete trait.
      expect(html).to include("Methodology")
    end

    it "renders the limitations section" do
      html = capture_html
      expect(html).to include("Limitations")
    end

    it "renders the signature line" do
      html = capture_html
      expect(html).to include("report-signature-block")
      expect(html).to include("Reviewed by")
    end
  end

  # ---------------------------------------------------------------------------
  # Conditional rendering: with a completed CaptureSession + captures whose GPS
  # is genuinely near the geocoded address -> GPS verification IS asserted.
  # ---------------------------------------------------------------------------

  describe "with a completed CaptureSession (GPS near the address)" do
    let!(:capture_session) do
      create(:capture_session, job: job, ended_at: Time.current - 1.hour)
    end
    let!(:captures) do
      [
        create(:capture, capture_session: capture_session, sequence_index: 0,
               photo_ref: "uploads/#{job.id}/photo_0.jpg",
               gps: { "latitude" => addr_lat, "longitude" => addr_lon }),
        create(:capture, capture_session: capture_session, sequence_index: 1,
               photo_ref: "uploads/#{job.id}/photo_1.jpg",
               gps: { "latitude" => addr_lat, "longitude" => addr_lon })
      ]
    end

    let(:thumbnail_response) do
      {
        "pipelineSchemaVersion" => PipelineSchema.version,
        "job_id" => job.id,
        "thumbnails" => [
          { "thumbnail_ref" => "artifacts/#{job.id}/evidence/0.jpg", "sequence_index" => 0, "caption" => nil },
          { "thumbnail_ref" => "artifacts/#{job.id}/evidence/1.jpg", "sequence_index" => 1, "caption" => nil }
        ]
      }
    end

    before do
      allow(SidecarClient).to receive(:render_evidence_thumbnails)
        .and_return(thumbnail_response)
    end

    it "renders the GPS-verified site visit block with timestamp and count" do
      html = capture_html
      expect(html).to include("GPS-Verified Site Visit")
      expect(html).to include("2 photos")
      expect(html).to match(/within 12 m of the geocoded address/)
    end

    it "renders the evidence photos block with images" do
      html = capture_html
      expect(html).to include("On-site photos")
      expect(html).to include("report-evidence-grid")
      # Both evidence images should be referenced.
      expect(html).to include("evidence/0.jpg")
      expect(html).to include("evidence/1.jpg")
    end

    it "calls render_evidence_thumbnails with photos ordered by sequence_index" do
      capture_html
      expect(SidecarClient).to have_received(:render_evidence_thumbnails) do |job_id:, photos:, **|
        expect(job_id).to eq(job.id)
        indices = photos.map { |p| p["sequence_index"] }
        expect(indices).to eq(indices.sort)
      end
    end

    it "caps evidence photos at EVIDENCE_PHOTO_CAP (4)" do
      # Create 6 captures; only 4 should appear.
      (2..5).each do |i|
        create(:capture, capture_session: capture_session, sequence_index: i,
               photo_ref: "uploads/#{job.id}/photo_#{i}.jpg")
      end
      extra_thumbs = (0..5).map do |i|
        { "thumbnail_ref" => "artifacts/#{job.id}/evidence/#{i}.jpg",
          "sequence_index" => i, "caption" => nil }
      end
      allow(SidecarClient).to receive(:render_evidence_thumbnails)
        .and_return(thumbnail_response.merge("thumbnails" => extra_thumbs))
      html = capture_html
      # Count evidence-item occurrences — should be at most 4.
      evidence_item_count = html.scan("report-evidence-item").count
      expect(evidence_item_count).to be <= ReportPdf::EVIDENCE_PHOTO_CAP
    end
  end

  # ---------------------------------------------------------------------------
  # HONEST GPS verification: a completed CaptureSession whose captures' GPS is
  # NOT within the radius (the factory default GPS is hundreds of km away) must
  # NOT assert GPS verification.
  # ---------------------------------------------------------------------------

  describe "with a completed CaptureSession (GPS far from the address)" do
    let!(:capture_session) do
      create(:capture_session, job: job, ended_at: Time.current - 1.hour)
    end
    let!(:capture) do
      # Factory default gps is 40.808 / -96.706 — far from the DC geocode.
      create(:capture, capture_session: capture_session, sequence_index: 0,
             photo_ref: "uploads/#{job.id}/photo_0.jpg")
    end

    before do
      allow(SidecarClient).to receive(:render_evidence_thumbnails).and_return(
        { "thumbnails" => [ { "thumbnail_ref" => "artifacts/#{job.id}/evidence/0.jpg",
                              "sequence_index" => 0, "caption" => nil } ] }
      )
    end

    it "renders a (non-GPS) site-visit block without asserting GPS verification" do
      html = capture_html
      expect(html).to include("Site Visit")
      expect(html).not_to include("GPS-Verified Site Visit")
      expect(html).not_to match(/verified by GPS/i)
    end

    it "states GPS could not place a capture within the radius" do
      html = capture_html
      expect(html).to match(/could not place a capture within 12 m/)
    end
  end

  describe "with a completed CaptureSession but no capture GPS at all" do
    let!(:capture_session) do
      create(:capture_session, job: job, ended_at: Time.current - 1.hour)
    end
    let!(:capture) do
      create(:capture, capture_session: capture_session, sequence_index: 0,
             photo_ref: "uploads/#{job.id}/photo_0.jpg", gps: nil)
    end

    before do
      allow(SidecarClient).to receive(:render_evidence_thumbnails).and_return(
        { "thumbnails" => [ { "thumbnail_ref" => "artifacts/#{job.id}/evidence/0.jpg",
                              "sequence_index" => 0, "caption" => nil } ] }
      )
    end

    it "does not assert GPS verification when GPS is missing" do
      html = capture_html
      expect(html).not_to include("GPS-Verified Site Visit")
      expect(html).to match(/GPS coordinates were not available/)
    end
  end

  # ---------------------------------------------------------------------------
  # Evidence seam: degrades on SidecarClient::Error
  # ---------------------------------------------------------------------------

  describe "evidence thumbnail degradation" do
    let!(:capture_session) { create(:capture_session, job: job, ended_at: 1.hour.ago) }
    let!(:_capture) do
      create(:capture, capture_session: capture_session, sequence_index: 0,
             photo_ref: "uploads/#{job.id}/photo_0.jpg")
    end

    before do
      allow(SidecarClient).to receive(:render_evidence_thumbnails)
        .and_raise(SidecarClient::Error, "sidecar unavailable")
    end

    it "omits the evidence block rather than raising" do
      expect { described_class.new(job, store: store).render }.not_to raise_error
    end

    it "renders without an evidence photos block" do
      html = capture_html
      expect(html).not_to include("On-site photos")
      expect(html).not_to include("report-evidence-grid")
    end
  end

  # ---------------------------------------------------------------------------
  # Methodology text from provenance
  # ---------------------------------------------------------------------------

  describe "methodology text" do
    it "includes provenance-derived imagery source in the methodology section" do
      html = capture_html
      # The :complete factory provenance includes NAIP and Mapbox imagery.
      expect(html).to match(/NAIP|Mapbox/i)
    end

    it "includes provenance-derived detector in the methodology section" do
      html = capture_html
      # The :complete factory provenance has detector 'openrouter'.
      expect(html).to include("openrouter")
    end
  end

  # ---------------------------------------------------------------------------
  # Reproducibility: two renders produce the same HTML modulo generated_at
  # ---------------------------------------------------------------------------

  describe "reproducibility" do
    it "produces identical HTML on two renders of the same measurement" do
      first_html = nil
      second_html = nil

      allow(Grover).to receive(:new) do |html, *|
        first_html = html
        grover_double
      end
      described_class.new(job, store: store).render

      allow(Grover).to receive(:new) do |html, *|
        second_html = html
        grover_double
      end
      described_class.new(job, store: store).render

      # Strip generated_at timestamps (format YYYY-MM-DD HH:MM UTC) before comparing.
      normalize = ->(html) { html.gsub(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC/, "__TS__") }
      expect(normalize.call(first_html)).to eq(normalize.call(second_html))
    end
  end
end
