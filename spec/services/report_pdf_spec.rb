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

  before do
    allow(SidecarClient).to receive(:render_images)
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
      expect(SidecarClient).to have_received(:render_images) do |job_id:, bbox:, width_px:, height_px:, **|
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
        .with(key: "artifacts/#{job.id}/report.pdf", body: pdf_bytes, content_type: "application/pdf")
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
  end

  describe "#render (sidecar failure -> Mapbox Static fallback)" do
    let(:fallback_bytes) { "PNGFALLBACKBYTES" }
    let(:fallback_ref) { "artifacts/#{job.id}/images/map-fallback.png" }

    before do
      allow(SidecarClient).to receive(:render_images).and_raise(SidecarClient::Error, "boom")
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
    it "returns the existing signed URL without re-rendering when a fresh PDF exists" do
      allow(store).to receive(:head)
        .with("artifacts/#{job.id}/report.pdf")
        .and_return(last_modified: 5.minutes.ago)
      expect(render).to eq(signed_pdf_url)
      expect(SidecarClient).not_to have_received(:render_images)
      expect(grover_double).not_to have_received(:to_pdf)
      expect(store).not_to have_received(:put)
    end

    it "re-renders when the existing PDF is older than 30 minutes" do
      allow(store).to receive(:head)
        .with("artifacts/#{job.id}/report.pdf")
        .and_return(last_modified: 31.minutes.ago)
      render
      expect(SidecarClient).to have_received(:render_images)
      expect(grover_double).to have_received(:to_pdf)
      expect(store).to have_received(:put)
    end
  end
end
