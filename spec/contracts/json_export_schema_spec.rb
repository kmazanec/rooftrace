require "rails_helper"
require "json_schemer"

# Contract test for the public JSON export schema (ADR-015,
# shared/json_export.schema.json). This is the integration contract downstream
# consumers (insurance, estimating tools) script against; it is INDEPENDENT of
# the internal pipeline schema (its own schema_version 1.0.0). The export
# serializer that produces these documents lands in the report workstream; this
# spec freezes the schema's shape so that serializer has a stable target.
RSpec.describe "shared/json_export.schema.json" do
  schema_path = Rails.root.join("shared/json_export.schema.json")
  meta_schema = "https://json-schema.org/draft/2020-12/schema"

  let(:document) { JSON.parse(File.read(schema_path)) }
  let(:schemer) { JSONSchemer.schema(document, meta_schema: meta_schema) }

  it "exists and is valid JSON" do
    expect(File).to exist(schema_path)
    expect { document }.not_to raise_error
  end

  it "declares draft 2020-12 and a schema_version const of 1.0.0" do
    expect(document["$schema"]).to eq(meta_schema)
    expect(document.dig("properties", "schema_version", "const")).to eq("1.0.0")
  end

  it "is itself a valid JSON Schema under the 2020-12 meta-schema" do
    meta = JSONSchemer.schema(JSON.parse(File.read(schema_path)), meta_schema: meta_schema)
    expect(meta).to be_a(JSONSchemer::Schema)
  end

  it "accepts a fully-populated export document" do
    doc = {
      "schema_version" => "1.0.0",
      "job" => { "id" => "job-1", "address" => "1600 Pennsylvania Ave NW", "status" => "ready" },
      "measurement" => {
        "generated_at" => "2026-05-28T00:00:00Z",
        "source" => "fusion",
        "confidence" => 0.82,
        "total_area_sq_ft" => 1200.0,
        "total_perimeter_ft" => 140.0,
        "predominant_pitch_ratio" => 6.0,
        "predominant_pitch_degrees" => 26.57,
        "warnings" => [ "lidar_missing: no 3DEP coverage" ],
        "facets" => [
          {
            "facet_id" => "F1",
            "vertices" => [ [ 38.8977, -77.0365 ], [ 38.8978, -77.0364 ], [ 38.8979, -77.0366 ] ],
            "pitch_ratio" => 6.0,
            "pitch_degrees" => 26.57,
            "area_sq_ft" => 600.0,
            "source" => "fusion",
            "confidence" => 0.8
          }
        ],
        "features" => [
          {
            "label" => "chimney",
            "bbox_norm" => [ 0.1, 0.1, 0.2, 0.2 ],
            "verified" => true,
            "source" => "imagery",
            "confidence" => 0.7
          }
        ],
        "geocode" => { "lat" => 38.8977, "lng" => -77.0365, "confidence" => 0.95 }
      },
      "provenance" => {
        "attributions" => { "imagery" => [ { "name" => "USDA NAIP" } ] },
        "retrieved_at" => { "imagery" => "2026-05-01T00:00:00Z" },
        "detector" => "openrouter",
        "sam2_backend" => "modal",
        "lidar_work_unit" => { "name" => "USGS_LPC_DC", "year" => 2018 },
        "pipeline_schema_version" => "0.3.0",
        "generated_at" => "2026-05-28T00:00:00Z"
      },
      "artifacts" => {
        "pdf_url" => "https://spaces.example/signed.pdf",
        "share_url" => "https://rooftrace.biograph.dev/r/abc123",
        "model_3d_url" => nil
      }
    }
    expect(schemer.validate(doc).to_a).to eq([])
  end

  it "accepts a not-ready document with null measurement and null artifact urls" do
    doc = {
      "schema_version" => "1.0.0",
      "job" => { "id" => "job-1", "address" => nil, "status" => "fetching_imagery" },
      "measurement" => nil,
      "provenance" => nil,
      "artifacts" => { "pdf_url" => nil, "share_url" => nil, "model_3d_url" => nil }
    }
    expect(schemer.validate(doc).to_a).to eq([])
  end

  it "rejects a wrong schema_version constant" do
    doc = {
      "schema_version" => "2.0.0",
      "job" => { "id" => "job-1", "status" => "ready" },
      "measurement" => nil,
      "provenance" => nil,
      "artifacts" => { "pdf_url" => nil, "share_url" => nil, "model_3d_url" => nil }
    }
    expect(schemer.validate(doc).to_a).not_to be_empty
  end

  it "rejects a non-null model_3d_url (3D export deferred in v1)" do
    doc = {
      "schema_version" => "1.0.0",
      "job" => { "id" => "job-1", "status" => "ready" },
      "measurement" => nil,
      "provenance" => nil,
      "artifacts" => { "pdf_url" => nil, "share_url" => nil, "model_3d_url" => "https://x/model.glb" }
    }
    expect(schemer.validate(doc).to_a).not_to be_empty
  end
end
