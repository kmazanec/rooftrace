require "rails_helper"

RSpec.describe MeasurementViewerSerializer do
  let(:job) { create(:job, address: "123 Main St, Springfield, IL") }
  let(:measurement) { create(:measurement, :with_geometry, job: job) }
  let(:payload) { described_class.new(measurement).as_json }

  it "emits the top-level scalar roll-ups from the real row" do
    expect(payload[:address]).to eq("123 Main St, Springfield, IL")
    expect(payload[:source]).to eq("lidar")
    expect(payload[:confidence]).to eq(0.9)
    expect(payload[:total_area_sq_ft]).to eq(1684.0)
    expect(payload[:total_perimeter_ft]).to eq(168.0)
    expect(payload[:primary_pitch_ratio]).to eq(6.0)
  end

  it "emits an iso8601 generated_at" do
    expect(payload[:generated_at]).to eq(measurement.generated_at.iso8601)
  end

  it "DERIVES primary_pitch_degrees from the stored ratio (atan(ratio/12))" do
    expected = (Math.atan(6.0 / 12.0) * 180.0 / Math::PI).round(2)
    expect(payload[:primary_pitch_degrees]).to eq(expected)
  end

  it "passes facets through with exactly the viewer-needed keys (no invented fields)" do
    facet = payload[:facets].first
    expect(facet.keys).to match_array(%i[facet_id vertices pitch_ratio pitch_degrees area_sq_ft source confidence])
    expect(facet[:facet_id]).to eq("F1")
    expect(facet[:vertices]).to eq(measurement.facets.first["vertices"])
    expect(facet[:pitch_degrees]).to eq(26.57)
  end

  it "passes features through with exactly the viewer-needed keys" do
    feature = payload[:features].first
    expect(feature.keys).to match_array(%i[label bbox_norm verified source confidence])
    expect(feature[:label]).to eq("chimney")
  end

  it "computes bounds [minLon, minLat, maxLon, maxLat] across all facet vertices" do
    bounds = payload[:bounds]
    expect(bounds).to be_an(Array)
    expect(bounds.size).to eq(4)
    expect(bounds[0]).to be_within(1e-9).of(-89.65030) # minLon
    expect(bounds[1]).to be_within(1e-9).of(39.79890)  # minLat
    expect(bounds[2]).to be_within(1e-9).of(-89.64990) # maxLon
    # maxLat comes from the roof_outline ring (39.79920), which extends past the
    # facets — bounds must union facets + outline + footprint.
    expect(bounds[3]).to be_within(1e-9).of(39.79920)  # maxLat
  end

  it "includes the roof_outline GeoJSON when present" do
    expect(payload[:roof_outline]).to eq(measurement.roof_outline)
  end

  it "flattens provenance.attributions for the footer, falling back to the full list" do
    expect(payload[:attributions]).to be_an(Array)
    expect(payload[:attributions]).to include("Mapbox")
  end

  it "emits warnings" do
    expect(payload[:warnings]).to eq([])
  end

  context "with no provenance attributions" do
    let(:measurement) { create(:measurement, :with_geometry, job: job, provenance: {}) }

    it "falls back to the static canonical source list" do
      expect(payload[:attributions]).to include(
        "Mapbox", "USGS 3DEP", "Microsoft Building Footprints", "Regrid", "Nominatim"
      )
    end
  end
end
