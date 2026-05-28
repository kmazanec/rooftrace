require "rails_helper"

# Loader/validator spec for JsonExportSchema (the Rails-side view of the public
# export contract, ADR-015). Mirrors spec/contracts/pipeline_schema-style loader
# coverage: the schema loads, exposes the locked version, validates a green
# payload, and rejects a broken one with a useful pointer.
RSpec.describe JsonExportSchema do
  it "loads the schema without error" do
    expect { described_class.load! }.not_to raise_error
  end

  it "exposes the locked contract version 1.0.0" do
    expect(described_class.version).to eq("1.0.0")
  end

  it "validates a minimal not-ready export document green" do
    doc = {
      "schema_version" => "1.0.0",
      "job" => { "id" => "job-1", "address" => nil, "status" => "pending" },
      "measurement" => nil,
      "provenance" => nil,
      "artifacts" => { "pdf_url" => nil, "share_url" => nil, "model_3d_url" => nil }
    }
    expect(described_class.valid?(doc)).to be(true)
    expect(described_class.errors_for(doc)).to eq([])
  end

  it "validates the committed sample fixture green" do
    sample = JSON.parse(File.read(Rails.root.join("spec/fixtures/json_export/sample.json")))
    expect(described_class.errors_for(sample)).to eq([])
    expect(described_class.valid?(sample)).to be(true)
  end

  it "rejects a document missing a required top-level field with a useful pointer" do
    doc = {
      "job" => { "id" => "job-1", "status" => "ready" },
      "measurement" => nil,
      "provenance" => nil,
      "artifacts" => { "pdf_url" => nil, "share_url" => nil, "model_3d_url" => nil }
    }
    expect(described_class.valid?(doc)).to be(false)
    expect(described_class.errors_for(doc)).not_to be_empty
  end

  # Breaking-change guard (CI): reading the schema's own `required` array and
  # asserting the locked v1.0.0 field set. Removing a field from `required`
  # (rather than a whole field from the doc) is a contract-breaking change that
  # the validate-a-sample-doc tests above do NOT catch — a doc that still happens
  # to carry the now-optional field validates either way. This asserts the locked
  # set so dropping any required field fails CI.
  it "preserves the exact v1.0.0 required top-level field set" do
    expect(described_class.document["required"]).to contain_exactly(
      "schema_version", "job", "measurement", "provenance", "artifacts"
    )
  end
end
