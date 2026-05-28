require "rails_helper"

# JobExportSerializer is the stateless transform from a Job + its
# latest_measurement into the public export shape (shared/json_export.schema.json,
# ADR-015). It maps the internal Measurement (WGS84 [lon, lat] vertices, numeric
# pitch rise-per-12, nested provenance) to the public contract ([lat, lng]
# vertices, derived pitch degrees). It does NOT validate (the controller does)
# and accepts artifact URLs as injected args (no url_helpers / hard-coded host).
RSpec.describe JobExportSerializer do
  let(:job) { create(:job, address: "1600 Pennsylvania Ave NW", status: "ready") }

  let(:facet) do
    {
      "facet_id" => "F1",
      # Internal storage is WGS84 [lon, lat]; the export FLIPS to [lat, lng].
      "vertices" => [ [ -77.0365, 38.8977 ], [ -77.0364, 38.8978 ], [ -77.0366, 38.8979 ] ],
      "pitch_ratio" => 6.0,
      "pitch_degrees" => 26.57,
      "area_sq_ft" => 600.0,
      "source" => "fusion",
      "confidence" => 0.8
    }
  end

  let(:feature) do
    {
      "label" => "chimney",
      "bbox_norm" => [ 0.1, 0.1, 0.2, 0.2 ],
      "verified" => true,
      "source" => "imagery",
      "confidence" => 0.7
    }
  end

  let(:provenance) do
    {
      "pipeline_schema_version" => "0.3.0",
      "detector" => "openrouter",
      "sam2_backend" => "modal",
      "attributions" => { "imagery" => [ { "name" => "USDA NAIP" } ] },
      "retrieved_at" => { "imagery" => "2026-05-01T00:00:00Z" },
      "lidar_work_unit" => { "name" => "USGS_LPC_DC", "year" => 2018 },
      "generated_at" => "2026-05-28T00:00:00Z"
    }
  end

  let!(:measurement) do
    create(
      :measurement,
      job: job,
      source: "fusion",
      confidence: 0.82,
      total_area_sq_ft: 1200.0,
      total_perimeter_ft: 140.0,
      predominant_pitch_ratio: 6.0,
      facets: [ facet ],
      features: [ feature ],
      provenance: provenance,
      warnings: [ "lidar_missing: no 3DEP coverage" ],
      geocode: { "raw" => "1600 Pennsylvania Ave NW", "lon" => -77.0365, "lat" => 38.8977, "confidence" => 0.95 },
      generated_at: Time.utc(2026, 5, 28)
    )
  end

  subject(:hash) { described_class.new(job).to_h }

  it "produces a hash that validates green against the export schema" do
    expect(JsonExportSchema.errors_for(hash)).to eq([])
    expect(JsonExportSchema.valid?(hash)).to be(true)
  end

  it "sets schema_version from the schema (not a literal)" do
    expect(hash["schema_version"]).to eq(JsonExportSchema.version)
    expect(hash["schema_version"]).to eq("1.0.0")
  end

  it "maps the job block" do
    expect(hash["job"]).to eq(
      "id" => job.id,
      "address" => "1600 Pennsylvania Ave NW",
      "status" => "ready"
    )
  end

  it "keeps facet_id and FLIPS vertices from [lon, lat] to [lat, lng]" do
    out_facet = hash.dig("measurement", "facets", 0)
    expect(out_facet["facet_id"]).to eq("F1")
    expect(out_facet["vertices"]).to eq(
      [ [ 38.8977, -77.0365 ], [ 38.8978, -77.0364 ], [ 38.8979, -77.0366 ] ]
    )
    expect(out_facet["pitch_ratio"]).to eq(6.0)
    expect(out_facet["area_sq_ft"]).to eq(600.0)
    expect(out_facet["source"]).to eq("fusion")
    expect(out_facet["confidence"]).to eq(0.8)
  end

  it "passes features through without inventing a geographic position" do
    out_feature = hash.dig("measurement", "features", 0)
    expect(out_feature["label"]).to eq("chimney")
    expect(out_feature["bbox_norm"]).to eq([ 0.1, 0.1, 0.2, 0.2 ])
    expect(out_feature["verified"]).to be(true)
    expect(out_feature["source"]).to eq("imagery")
    expect(out_feature["confidence"]).to eq(0.7)
    expect(out_feature).not_to have_key("position_lat_lng")
  end

  it "derives predominant_pitch_degrees from the ratio (atan(ratio/12))" do
    m = hash["measurement"]
    expect(m["predominant_pitch_ratio"]).to eq(6.0)
    expected = Math.atan(6.0 / 12.0) * 180.0 / Math::PI
    expect(m["predominant_pitch_degrees"]).to be_within(0.01).of(expected)
    expect(m["predominant_pitch_degrees"]).to be_within(0.01).of(26.57)
  end

  it "carries the measurement scalars and warnings" do
    m = hash["measurement"]
    expect(m["generated_at"]).to eq(Time.utc(2026, 5, 28).iso8601)
    expect(m["source"]).to eq("fusion")
    expect(m["confidence"]).to eq(0.82)
    expect(m["total_area_sq_ft"]).to eq(1200.0)
    expect(m["total_perimeter_ft"]).to eq(140.0)
    expect(m["warnings"]).to eq([ "lidar_missing: no 3DEP coverage" ])
  end

  it "maps geocode to lat/lng (NOT the internal lon/lat key names)" do
    g = hash.dig("measurement", "geocode")
    expect(g["lat"]).to eq(38.8977)
    expect(g["lng"]).to eq(-77.0365)
    expect(g["confidence"]).to eq(0.95)
  end

  it "passes provenance through best-effort (nested shape preserved)" do
    p = hash["provenance"]
    expect(p["detector"]).to eq("openrouter")
    expect(p["sam2_backend"]).to eq("modal")
    expect(p["attributions"]).to eq("imagery" => [ { "name" => "USDA NAIP" } ])
    expect(p["lidar_work_unit"]).to eq("name" => "USGS_LPC_DC", "year" => 2018)
  end

  # The export — not the orchestrator — is the trust boundary for this anonymous,
  # CORS-open surface. Provenance is the only schema block with
  # additionalProperties:true, so the serializer allowlists known keys: an
  # internal-only field a future orchestrator change drops into the provenance
  # jsonb must NOT silently re-export.
  context "when provenance carries an unexpected internal key" do
    let(:provenance) do
      {
        "detector" => "openrouter",
        "sam2_backend" => "modal",
        "internal_endpoint" => "http://sidecar:8000",
        "raw_source_ip" => "10.0.0.5"
      }
    end

    it "drops keys outside the allowlist while keeping the documented ones" do
      p = hash["provenance"]
      expect(p).not_to have_key("internal_endpoint")
      expect(p).not_to have_key("raw_source_ip")
      expect(p["detector"]).to eq("openrouter")
      expect(p["sam2_backend"]).to eq("modal")
    end
  end

  it "injects artifact urls and always-null model_3d_url" do
    h = described_class.new(
      job,
      share_url: "https://rooftrace.biograph.dev/r/abc123",
      pdf_url: "https://spaces.example/signed.pdf"
    ).to_h
    expect(h["artifacts"]).to eq(
      "pdf_url" => "https://spaces.example/signed.pdf",
      "share_url" => "https://rooftrace.biograph.dev/r/abc123",
      "model_3d_url" => nil
    )
  end

  it "nulls artifact urls when none injected" do
    expect(hash["artifacts"]).to eq(
      "pdf_url" => nil, "share_url" => nil, "model_3d_url" => nil
    )
  end

  context "with no measurement (not-ready job)" do
    let!(:measurement) { nil }
    let(:job) { create(:job, address: "123 Main St", status: "fetching_imagery") }

    it "emits null measurement + provenance and still validates green" do
      h = described_class.new(job).to_h
      expect(h["measurement"]).to be_nil
      expect(h["provenance"]).to be_nil
      expect(h.dig("job", "status")).to eq("fetching_imagery")
      expect(JsonExportSchema.errors_for(h)).to eq([])
    end
  end

  context "when geocode has no lat/lng" do
    let!(:measurement) do
      create(:measurement, job: job, facets: [], features: [], geocode: nil,
                           predominant_pitch_ratio: nil, generated_at: Time.current)
    end

    it "emits a null geocode and a null predominant_pitch_degrees" do
      h = described_class.new(job).to_h
      expect(h.dig("measurement", "geocode")).to be_nil
      expect(h.dig("measurement", "predominant_pitch_degrees")).to be_nil
      expect(JsonExportSchema.errors_for(h)).to eq([])
    end
  end
end
