require "rails_helper"

# Guards the :with_geometry factory trait against the FROZEN Facet/Feature
# $defs in shared/pipeline_schema.json. If the orchestrator's real output shape
# drifts, this fails loudly so the viewer fixtures can never lie about the
# contract they consume.
RSpec.describe "Measurement :with_geometry factory contract" do
  let(:measurement) { build(:measurement, :with_geometry) }

  it "produces facets that validate against the frozen Facet schema" do
    measurement.facets.each do |facet|
      errors = PipelineSchema.errors_for("Facet", facet)
      expect(errors).to be_empty, "facet #{facet['facet_id']}: #{errors.join(', ')}"
    end
  end

  it "produces features that validate against the frozen Feature schema" do
    measurement.features.each do |feature|
      errors = PipelineSchema.errors_for("Feature", feature)
      expect(errors).to be_empty, "feature #{feature['label']}: #{errors.join(', ')}"
    end
  end

  it "has at least two facets and one feature so the viewer renders meaningfully" do
    expect(measurement.facets.size).to be >= 2
    expect(measurement.features.size).to be >= 1
  end
end
