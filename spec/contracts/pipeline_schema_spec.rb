require "rails_helper"

# Ruby half of the F-02 contract test. Validates every fixture in
# spec/fixtures/pipeline/ against shared/pipeline_schema.json. The Python
# sidecar runs an equivalent test against the SAME files
# (sidecar/tests/test_pipeline_contract.py); if the two languages disagree about
# a fixture, one of these suites goes red.
RSpec.describe PipelineSchema do
  fixture_dir = Rails.root.join("spec/fixtures/pipeline")
  fixtures = Dir[fixture_dir.join("*.json")].sort

  it "loads the schema and exposes its version" do
    expect(described_class.version).to eq("0.2.0")
    expect(described_class.document["$id"]).to include("pipeline_schema.json")
  end

  it "raises on an unknown entity" do
    expect { described_class.valid?("Nonsense", {}) }
      .to raise_error(PipelineSchema::UnknownEntity)
  end

  it "has at least one fixture to validate" do
    expect(fixtures).not_to be_empty
  end

  fixtures.each do |path|
    name = File.basename(path)
    fixture = JSON.parse(File.read(path))
    entity = fixture.fetch("entity")
    expected_valid = fixture.fetch("valid")
    payload = fixture.fetch("payload")

    it "#{name}: #{entity} validates #{expected_valid ? 'green' : 'red'}" do
      errors = described_class.errors_for(entity, payload)
      if expected_valid
        expect(errors).to(be_empty, "expected #{name} to be valid, got: #{errors.join('; ')}")
      else
        expect(errors).not_to(be_empty, "expected #{name} to be rejected, but it validated")
      end
    end
  end
end
