require "rails_helper"

# ReportMethodology generates the claim-defensible methodology footnote for
# the PDF from Measurement#provenance, never from hardcoded strings (ADR-018).
RSpec.describe ReportMethodology do
  def make_measurement(provenance)
    m = instance_double("Measurement")
    allow(m).to receive(:provenance).and_return(provenance)
    m
  end

  let(:full_provenance) do
    {
      "pipeline_schema_version" => "0.4.0",
      "detector" => "gemini-flash-2.0",
      "sam2_backend" => "replicate",
      "geometry_source" => "fusion",
      "fusion_icp_rmse_m" => "0.09",
      "attributions" => {
        "imagery" => [
          { "name" => "Mapbox", "retrieved_at" => "2024-08-12T00:00:00Z" }
        ],
        "lidar" => [
          { "name" => "USGS 3DEP", "retrieved_at" => "2021-04-15T00:00:00Z" }
        ],
        "resolve_address" => [
          { "name" => "Nominatim", "retrieved_at" => "2026-05-28T00:00:00Z" }
        ]
      }
    }
  end

  let(:imagery_only_provenance) do
    {
      "detector" => "gemini-flash-2.0",
      "geometry_source" => "imagery",
      "attributions" => {
        "imagery" => [
          { "name" => "Mapbox", "retrieved_at" => "2024-08-12T00:00:00Z" }
        ]
      }
    }
  end

  describe ".call" do
    it "returns an Array" do
      measurement = make_measurement(full_provenance)
      expect(described_class.call(measurement)).to be_an(Array)
    end
  end

  describe "full provenance (imagery + LiDAR + on-site ICP)" do
    subject(:sentences) { described_class.call(make_measurement(full_provenance)) }

    it "includes an imagery sentence naming the source and acquisition date" do
      expect(sentences.any? { |s| s.include?("Mapbox") && s.include?("2024-08-12") }).to be true
    end

    it "includes a LiDAR sentence naming the source" do
      expect(sentences.any? { |s| s.include?("USGS 3DEP") && s.include?("2021-04-15") }).to be true
    end

    it "includes a geometry method sentence" do
      expect(sentences.any? { |s| s.match?(/geometry method/i) }).to be true
    end

    it "includes a feature-detection sentence naming the model" do
      expect(sentences.any? { |s| s.include?("gemini-flash-2.0") }).to be true
    end

    it "includes an on-site ICP sentence with the RMSE" do
      expect(sentences.any? { |s| s.match?(/ICP.*0\.09\s*m/i) || s.match?(/0\.09\s*m.*ICP/i) }).to be true
    end

    it "produces no empty or nil sentences" do
      expect(sentences.all?(&:present?)).to be true
    end
  end

  describe "imagery-only provenance (no LiDAR, no on-site)" do
    subject(:sentences) { described_class.call(make_measurement(imagery_only_provenance)) }

    it "includes an imagery sentence" do
      expect(sentences.any? { |s| s.include?("Mapbox") }).to be true
    end

    it "omits the LiDAR sentence" do
      expect(sentences.none? { |s| s.match?(/LiDAR.*USGS/i) }).to be true
    end

    it "omits the on-site ICP sentence" do
      expect(sentences.none? { |s| s.match?(/ICP/i) }).to be true
    end

    it "does not include N/A placeholders" do
      expect(sentences.none? { |s| s.include?("N/A") }).to be true
    end
  end

  describe "empty provenance" do
    subject(:sentences) { described_class.call(make_measurement({})) }

    it "returns an Array (no crash)" do
      expect { sentences }.not_to raise_error
    end

    it "omits imagery, LiDAR, and on-site sentences" do
      expect(sentences.none? { |s| s.match?(/Mapbox|USGS|ICP/i) }).to be true
    end
  end

  describe "nil provenance" do
    subject(:sentences) { described_class.call(make_measurement(nil)) }

    it "returns an Array without crashing" do
      expect { sentences }.not_to raise_error
      expect(sentences).to be_an(Array)
    end
  end
end
