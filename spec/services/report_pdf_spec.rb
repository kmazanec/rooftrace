require "rails_helper"

# ReportPdf orchestrates the two-hop PDF pipeline (ADR-014, as amended):
#   1. ask the sidecar to render a top-down map PNG (single image_ref),
#   2. mint a signed artifacts/ URL for that PNG,
#   3. render the print-layout ERB to HTML,
#   4. run Grover (Puppeteer) to PDF bytes,
#   5. upload the PDF to artifacts/<job_id>/report.pdf,
#   6. return a signed URL to the PDF.
#
# Idempotency: a fresh report.pdf object (<30 min old) is reused without
# re-render. A sidecar render failure degrades to the Mapbox Static fallback
# with a warning flag surfaced to the template (never an exception).
RSpec.describe ReportPdf do
  let(:job) { create(:job) }
  let!(:measurement) { create(:measurement, :complete, job: job) }

  let(:image_ref) { "artifacts/#{job.id}/images/map-abc123.png" }
  let(:pdf_bytes) { "%PDF-1.4\nfake pdf bytes\n%%EOF" }
  let(:signed_map_url) { "https://spaces.example.com/#{image_ref}?signed=map" }
  let(:signed_pdf_url) { "https://spaces.example.com/artifacts/#{job.id}/report.pdf?signed=pdf" }

  # Fake artifact store: in-memory head/put so we never touch real Spaces.
  let(:store) { instance_double("ArtifactStore") }
  let(:grover_double) { instance_double(Grover, to_pdf: pdf_bytes) }
  # Instance double for SidecarClient; SidecarClient.new is stubbed to return it
  # so both ReportPdf (render_images) and EvidencePhotos (render_evidence_thumbnails)
  # share the same controllable instance.
  let(:sidecar_instance) { instance_double(SidecarClient) }

  before do
    allow(SidecarClient).to receive(:new).and_return(sidecar_instance)
    allow(sidecar_instance).to receive(:render_images)
      .and_return({ "image_ref" => image_ref })
    allow(ArtifactUrlMinter).to receive(:call) do |object_key:, **|
      object_key.end_with?("report.pdf") ? signed_pdf_url : signed_map_url
    end
    allow(Grover).to receive(:new).and_return(grover_double)
    # No existing PDF in Spaces by default (idempotency miss).
    allow(store).to receive(:head).and_return(nil)
    allow(store).to receive(:put).and_return(true)
  end

  def render
    described_class.new(job, store: store).render
  end

  describe "#render (happy path)" do
    it "asks the sidecar to render a map PNG with a bbox computed from facet vertices" do
      render
      expect(sidecar_instance).to have_received(:render_images) do |job_id:, bbox:, width_px:, height_px:, **|
        expect(job_id).to eq(job.id)
        expect(width_px).to be >= 1
        expect(height_px).to be >= 1
        # bbox is WGS84 [min_lon, min_lat, max_lon, max_lat] enclosing the facets.
        min_lon, min_lat, max_lon, max_lat = bbox
        expect(min_lon).to be <= -104.9950
        expect(min_lat).to be <= 39.7380
        expect(max_lon).to be >= -104.9930
        expect(max_lat).to be >= 39.7390
      end
    end

    it "mints a signed URL over the rendered map PNG and embeds it in the HTML" do
      captured_html = nil
      allow(Grover).to receive(:new) do |html, *|
        captured_html = html
        grover_double
      end
      render
      expect(ArtifactUrlMinter).to have_received(:call).with(object_key: image_ref)
      expect(captured_html).to include(signed_map_url)
    end

    it "runs Grover to produce PDF bytes and uploads them to artifacts/<job_id>/report.pdf" do
      render
      expect(grover_double).to have_received(:to_pdf)
      expect(store).to have_received(:put)
        .with(hash_including(key: "artifacts/#{job.id}/report.pdf", body: pdf_bytes, content_type: "application/pdf"))
    end

    it "does NOT tag a clean (non-degraded) render with degraded metadata" do
      render
      expect(store).to have_received(:put).with(
        hash_including(key: "artifacts/#{job.id}/report.pdf", metadata: {})
      )
    end

    it "returns a signed URL to the uploaded PDF" do
      expect(render).to eq(signed_pdf_url)
    end
  end

  describe "#render (guards)" do
    it "raises a clear error when the job has no measurement" do
      measurement.destroy!
      expect { render }.to raise_error(ReportPdf::Error, /no measurement/i)
    end

    it "raises a rescued Error (not NoMethodError) when the job is nil (orphaned share)" do
      # An orphaned Report (job_id nullified by a destroyed Job) hands ReportPdf
      # a nil job; it must raise the catchable Error, never NoMethodError on nil.
      expect { ReportPdf.new(nil, store: store).render }
        .to raise_error(ReportPdf::Error, /no job/i)
    end
  end

  describe "#render (sidecar failure -> Mapbox Static fallback)" do
    let(:fallback_bytes) { "PNGFALLBACKBYTES" }
    let(:fallback_ref) { "artifacts/#{job.id}/images/map-fallback.png" }

    before do
      allow(sidecar_instance).to receive(:render_images).and_raise(SidecarClient::Error, "boom")
      allow(MapboxStaticFallback).to receive(:call).and_return(fallback_bytes)
    end

    it "engages the Mapbox Static fallback, uploads it, and does NOT raise" do
      allow(store).to receive(:put).and_return(true)
      expect { render }.not_to raise_error
      expect(MapboxStaticFallback).to have_received(:call)
      # The fallback PNG is uploaded under artifacts/ so it can be embedded.
      expect(store).to have_received(:put)
        .with(hash_including(content_type: "image/png"))
    end

    it "surfaces a fallback warning into the rendered template" do
      captured_html = nil
      allow(Grover).to receive(:new) do |html, *|
        captured_html = html
        grover_double
      end
      render
      expect(captured_html).to match(/static map|fallback|degraded/i)
    end
  end

  describe "#render (idempotency: 30-min Spaces-object-age window)" do
    # The measurement predates the cached PDF in these reuse cases, so the only
    # thing under test is the time window / degraded / data-change logic.
    before { measurement.update_column(:updated_at, 1.hour.ago) }

    it "returns the existing signed URL without re-rendering when a fresh PDF exists" do
      allow(store).to receive(:head)
        .with("artifacts/#{job.id}/report.pdf")
        .and_return(last_modified: 5.minutes.ago, metadata: {})
      expect(render).to eq(signed_pdf_url)
      expect(sidecar_instance).not_to have_received(:render_images)
      expect(grover_double).not_to have_received(:to_pdf)
      expect(store).not_to have_received(:put)
    end

    it "re-renders when the existing PDF is older than 30 minutes" do
      allow(store).to receive(:head)
        .with("artifacts/#{job.id}/report.pdf")
        .and_return(last_modified: 31.minutes.ago, metadata: {})
      render
      expect(sidecar_instance).to have_received(:render_images)
      expect(grover_double).to have_received(:to_pdf)
      expect(store).to have_received(:put)
    end

    it "re-renders when the cached PDF is a degraded render even if it is fresh" do
      allow(store).to receive(:head)
        .with("artifacts/#{job.id}/report.pdf")
        .and_return(last_modified: 5.minutes.ago, metadata: { "degraded" => "1" })
      render
      expect(sidecar_instance).to have_received(:render_images)
      expect(grover_double).to have_received(:to_pdf)
    end

    it "re-renders when the measurement is newer than the fresh cached PDF (data changed)" do
      measurement.update_column(:updated_at, 1.minute.ago)
      allow(store).to receive(:head)
        .with("artifacts/#{job.id}/report.pdf")
        .and_return(last_modified: 5.minutes.ago, metadata: {})
      render
      expect(sidecar_instance).to have_received(:render_images)
      expect(grover_double).to have_received(:to_pdf)
    end
  end

  describe "#render (degraded render is not cached as canonical)" do
    before do
      allow(sidecar_instance).to receive(:render_images).and_raise(SidecarClient::Error, "boom")
      allow(MapboxStaticFallback).to receive(:call).and_return("PNGFALLBACKBYTES")
    end

    it "tags the report.pdf object with degraded metadata so it is re-attempted next time" do
      render
      expect(store).to have_received(:put).with(
        hash_including(
          key: "artifacts/#{job.id}/report.pdf",
          content_type: "application/pdf",
          metadata: { "degraded" => "1" }
        )
      )
    end
  end

  describe "#render (Spaces unavailable during fallback upload does not 5xx)" do
    before do
      allow(sidecar_instance).to receive(:render_images).and_raise(SidecarClient::Error, "boom")
      allow(MapboxStaticFallback).to receive(:call).and_return("PNGFALLBACKBYTES")
    end

    it "degrades to a no-diagram report when the fallback PNG put raises ArtifactStore::Error" do
      allow(store).to receive(:put) do |key:, **|
        raise ArtifactStore::Error, "spaces down" if key.include?("map-fallback.png")
        true
      end
      captured_html = nil
      allow(Grover).to receive(:new) do |html, *|
        captured_html = html
        grover_double
      end
      expect { render }.not_to raise_error
      expect(captured_html).to match(/Roof diagram unavailable/i)
    end
  end

  describe "#render (malformed sidecar image_ref falls back, not 5xx)" do
    it "routes a non-artifacts/ image_ref to the Mapbox Static fallback" do
      allow(sidecar_instance).to receive(:render_images)
        .and_return({ "image_ref" => "cache/not-allowed.png" })
      # A bad (non-artifacts/) image_ref makes the minter raise; everything else
      # mints normally. The orchestrator must degrade, not 5xx.
      allow(ArtifactUrlMinter).to receive(:call) do |object_key:, **|
        raise ArtifactUrlMinter::Error, "bad prefix" if object_key == "cache/not-allowed.png"

        object_key.end_with?("report.pdf") ? signed_pdf_url : signed_map_url
      end
      allow(MapboxStaticFallback).to receive(:call).and_return("PNGFALLBACKBYTES")

      expect { render }.not_to raise_error
      expect(MapboxStaticFallback).to have_received(:call)
    end
  end

  # The PDF evidence seam (ADR-019): the report's evidence strip prefers projected
  # composites (most pose-confident first) over raw capture thumbnails.
  describe "#evidence_photos_for (composite preference)" do
    let(:session) { create(:capture_session, job: job) }

    def evidence_photos
      described_class.new(job, store: store).send(:evidence_photos_for, measurement)
    end

    it "prefers projected composites, most pose-confident first, capped at 4" do
      caps = Array.new(5) do |i|
        create(:capture, capture_session: session, sequence_index: i, prompt_label: "p#{i}")
      end
      caps.each_with_index do |cap, i|
        create(:projected_overlay, capture: cap,
               composite_ref: "artifacts/#{job.id}/projected/#{i}.png",
               pose_confidence: i / 10.0)
      end
      allow(ArtifactUrlMinter).to receive(:call) { |object_key:, **| "https://signed/#{object_key}" }

      photos = evidence_photos
      expect(photos.length).to eq(ReportPdf::EVIDENCE_PHOTO_CAP)
      expect(photos.map { |p| p[:kind] }.uniq).to eq([ "composite" ])
      # Highest pose_confidence (0.4) first.
      expect(photos.first[:image_url]).to eq("https://signed/artifacts/#{job.id}/projected/4.png")
    end

    it "falls through to thumbnails when there are no composites" do
      create(:capture, capture_session: session, sequence_index: 0, photo_ref: "uploads/#{job.id}/p0.jpg")
      allow(sidecar_instance).to receive(:render_evidence_thumbnails).and_return(
        { "thumbnails" => [ { "thumbnail_ref" => "artifacts/#{job.id}/evidence/0.jpg", "sequence_index" => 0 } ] }
      )
      allow(ArtifactUrlMinter).to receive(:call) { |object_key:, **| "https://signed/#{object_key}" }

      photos = evidence_photos
      expect(photos.map { |p| p[:kind] }.uniq).to eq([ "thumbnail" ])
    end

    it "skips a low_pose_confidence overlay (no composite_ref) when building composites" do
      cap = create(:capture, capture_session: session, sequence_index: 0, photo_ref: nil)
      create(:projected_overlay, capture: cap, composite_ref: nil, pose_confidence: 0.2,
             low_pose_confidence: true)
      # No composite + no captures-with-photos -> empty evidence strip, not a 5xx.
      expect(evidence_photos).to eq([])
    end
  end
end
