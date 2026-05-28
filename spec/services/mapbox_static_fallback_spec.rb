require "rails_helper"
require "webmock/rspec"

RSpec.describe MapboxStaticFallback do
  let(:token) { "pk.test-token" }
  let(:bbox) { [ -104.9950, 39.7380, -104.9940, 39.7390 ] }

  describe "#call" do
    it "fetches a static satellite PNG from the Mapbox host and returns the bytes" do
      stub = stub_request(:get, %r{\Ahttps://api\.mapbox\.com/styles/v1/mapbox/satellite-v9/static/})
             .to_return(status: 200, body: "PNGBYTES", headers: { "Content-Type" => "image/png" })

      bytes = described_class.call(bbox: bbox, width_px: 1600, height_px: 1200, token: token)
      expect(bytes).to eq("PNGBYTES")
      expect(stub).to have_been_requested
    end

    it "only ever requests api.mapbox.com (SSRF guard)" do
      stub_request(:get, %r{\Ahttps://api\.mapbox\.com/}).to_return(status: 200, body: "ok")
      described_class.call(bbox: bbox, width_px: 100, height_px: 100, token: token)
      expect(a_request(:get, %r{api\.mapbox\.com})).to have_been_made
    end

    it "raises (before building a URL) on an out-of-range bbox" do
      expect {
        described_class.call(bbox: [ 200.0, 39.0, 201.0, 40.0 ], width_px: 100, height_px: 100, token: token)
      }.to raise_error(described_class::Error, /range|inverted/i)
    end

    it "raises on an inverted bbox" do
      expect {
        described_class.call(bbox: [ 10.0, 10.0, 5.0, 5.0 ], width_px: 100, height_px: 100, token: token)
      }.to raise_error(described_class::Error, /range|inverted/i)
    end

    it "raises when the token is blank" do
      expect {
        described_class.call(bbox: bbox, width_px: 100, height_px: 100, token: "")
      }.to raise_error(described_class::Error, /token/i)
    end

    it "raises on a non-success Mapbox response" do
      stub_request(:get, %r{api\.mapbox\.com}).to_return(status: 422, body: "nope")
      expect {
        described_class.call(bbox: bbox, width_px: 100, height_px: 100, token: token)
      }.to raise_error(described_class::Error, /422/)
    end
  end
end
