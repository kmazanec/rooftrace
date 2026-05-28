require "rails_helper"
require "pdf-reader"
require "stringio"
require "base64"

# End-to-end PDF generation with REAL Grover (Puppeteer/headless Chromium) and
# the REAL print-layout ERB. The two network boundaries are stubbed so the test
# is hermetic:
#   - SidecarClient.render_images -> returns a fixed image_ref,
#   - ArtifactUrlMinter.call      -> returns a data: URL embedding a 1x1 PNG so
#                                     Grover embeds a real image object with no
#                                     network fetch,
#   - ArtifactStore#put           -> captures the produced PDF bytes (no Spaces).
#
# The produced PDF is parsed with pdf-reader and asserted to contain the address,
# the total-area number, a source label, attribution names, and an embedded
# image XObject (the roof diagram).
RSpec.describe "PDF report generation", type: :system do
  # A real 1x1 transparent PNG, embedded as a data: URL so Grover renders an
  # actual image object without any network round-trip.
  ONE_PX_PNG = Base64.strict_decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  ).freeze
  DATA_URL = "data:image/png;base64,#{Base64.strict_encode64(ONE_PX_PNG)}".freeze

  let(:job) { create(:job) }
  let!(:measurement) { create(:measurement, :complete, job: job) }
  let(:captured) { {} }

  before do
    allow(SidecarClient).to receive(:render_images)
      .and_return({ "image_ref" => "artifacts/#{job.id}/images/map-x.png" })
    allow(ArtifactUrlMinter).to receive(:call) do |object_key:, **|
      object_key.end_with?("report.pdf") ? "https://signed.example.com/report.pdf" : DATA_URL
    end
    store = instance_double(ArtifactStore)
    allow(store).to receive(:head).and_return(nil)
    allow(store).to receive(:put) do |key:, body:, content_type:|
      captured[:key] = key
      captured[:body] = body
      true
    end
    allow(ArtifactStore).to receive(:new).and_return(store)
  end

  def pdf_text(bytes)
    reader = PDF::Reader.new(StringIO.new(bytes))
    reader.pages.map(&:text).join("\n")
  end

  def pdf_has_image?(bytes)
    reader = PDF::Reader.new(StringIO.new(bytes))
    reader.pages.any? do |page|
      page.xobjects.values.any? { |xo| xo.hash[:Subtype] == :Image }
    end
  end

  it "renders a valid PDF with the address, totals, source label, attribution, and an embedded map image" do
    url = ReportPdf.new(job).render
    expect(url).to eq("https://signed.example.com/report.pdf")
    expect(captured[:key]).to eq("artifacts/#{job.id}/report.pdf")

    bytes = captured[:body]
    expect(bytes[0, 5]).to eq("%PDF-")

    # pdf-reader can drop kerned inter-word spaces, so compare with whitespace
    # squeezed out.
    text = pdf_text(bytes)
    expect(text.gsub(/\s+/, "")).to include("1600PennsylvaniaAvenueNW")  # geocode-normalized address
    expect(text).to include("2,481")                        # total area, rounded + delimited
    expect(text).to match(/Fusion/i)                        # source label
    expect(text).to include("USGS 3DEP")                    # attribution footer
    expect(text).to match(/Nominatim|NAIP|Mapbox/)          # attribution footer

    expect(pdf_has_image?(bytes)).to be(true)
  end

  it "falls back to the Mapbox Static image with a warning footer when the sidecar fails" do
    allow(SidecarClient).to receive(:render_images).and_raise(SidecarClient::Error, "down")
    allow(MapboxStaticFallback).to receive(:call).and_return(ONE_PX_PNG)

    ReportPdf.new(job).render
    bytes = captured[:body]
    expect(bytes[0, 5]).to eq("%PDF-")

    text = pdf_text(bytes)
    expect(text).to match(/static map|degraded/i)  # the fallback warning footer
    expect(pdf_has_image?(bytes)).to be(true)        # the static-map image is embedded
  end
end
