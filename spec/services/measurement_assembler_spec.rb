require "rails_helper"

# MeasurementAssembler is pure (no I/O, no DB, no Job mutation) — all methods
# take explicit arguments, so every example exercises the real object with no
# doubles needed.
RSpec.describe MeasurementAssembler, type: :service do
  subject(:assembler) { described_class.new }

  # Minimal resolve_address response shape that overall_confidence reads from.
  def resolve_with(geocode_confidence:)
    { "geocode" => { "confidence" => geocode_confidence } }
  end

  # Minimal geometry response shape.
  def geometry_with(confidence:, source: "fusion", facets: [], warnings: [])
    {
      "confidence" => confidence,
      "source" => source,
      "facets" => facets,
      "warnings" => warnings
    }
  end

  # ---------------------------------------------------------------------------
  # overall_confidence
  # ---------------------------------------------------------------------------

  describe "#overall_confidence" do
    context "with both geocode and geometry confidence (fusion path)" do
      it "returns the product of geocode * geometry confidences" do
        result = assembler.overall_confidence(
          resolve: resolve_with(geocode_confidence: 0.95),
          geometry: geometry_with(confidence: 0.9),
          lidar_available: true
        )
        # 0.95 * 0.9 = 0.855
        expect(result).to be_within(0.0001).of(0.855)
      end

      it "rounds to 4 decimal places" do
        result = assembler.overall_confidence(
          resolve: resolve_with(geocode_confidence: 1.0 / 3.0),
          geometry: geometry_with(confidence: 1.0),
          lidar_available: true
        )
        expect(result.to_s.split(".").last.length).to be <= 4
      end
    end

    context "empty-product identity (no factors)" do
      it "returns 1.0 (not 0.0) when both confidences are nil" do
        result = assembler.overall_confidence(
          resolve: { "geocode" => {} },
          geometry: geometry_with(confidence: nil),
          lidar_available: true
        )
        expect(result).to eq(1.0)
      end

      it "returns the sole geocode confidence when geometry confidence is nil" do
        result = assembler.overall_confidence(
          resolve: resolve_with(geocode_confidence: 0.8),
          geometry: geometry_with(confidence: nil),
          lidar_available: true
        )
        expect(result).to be_within(0.0001).of(0.8)
      end

      it "returns the sole geometry confidence when geocode is nil" do
        result = assembler.overall_confidence(
          resolve: { "geocode" => nil },
          geometry: geometry_with(confidence: 0.7),
          lidar_available: true
        )
        expect(result).to be_within(0.0001).of(0.7)
      end
    end

    context "imagery-only cap (lidar_available: false)" do
      it "caps the combined confidence at IMAGERY_CONFIDENCE_CAP (0.6)" do
        result = assembler.overall_confidence(
          resolve: resolve_with(geocode_confidence: 0.95),
          geometry: geometry_with(confidence: 0.9),
          lidar_available: false
        )
        expect(result).to eq(described_class::IMAGERY_CONFIDENCE_CAP)
      end

      it "does NOT raise above the cap when the raw product is 1.0" do
        result = assembler.overall_confidence(
          resolve: { "geocode" => {} },
          geometry: geometry_with(confidence: nil),
          lidar_available: false
        )
        expect(result).to eq(described_class::IMAGERY_CONFIDENCE_CAP)
      end

      it "returns the raw product when it is already below the cap" do
        result = assembler.overall_confidence(
          resolve: resolve_with(geocode_confidence: 0.5),
          geometry: geometry_with(confidence: 0.5),
          lidar_available: false
        )
        # 0.5 * 0.5 = 0.25, which is below the 0.6 cap
        expect(result).to be_within(0.0001).of(0.25)
      end

      it "IMAGERY_CONFIDENCE_CAP is 0.6" do
        expect(described_class::IMAGERY_CONFIDENCE_CAP).to eq(0.6)
      end
    end

    context "clamping" do
      it "clamps a product above 1.0 to 1.0" do
        # Defensive: individual stage confidences > 1 are a data error but should not
        # produce a confidence > 1.0 in the assembled result.
        result = assembler.overall_confidence(
          resolve: resolve_with(geocode_confidence: 1.1),
          geometry: geometry_with(confidence: 1.1),
          lidar_available: true
        )
        expect(result).to be <= 1.0
      end
    end
  end

  # ---------------------------------------------------------------------------
  # collect_warnings
  # ---------------------------------------------------------------------------

  describe "#collect_warnings" do
    it "merges warnings from all sources" do
      result = assembler.collect_warnings(
        accumulated: [ "lidar_missing: some reason" ],
        imagery: { "warnings" => [ "imagery_stale" ] },
        refined: { "warnings" => [ "outline_fallback" ] },
        geometry: { "warnings" => [ "low_coverage" ] }
      )
      expect(result).to include("lidar_missing: some reason", "imagery_stale",
                                "outline_fallback", "low_coverage")
    end

    it "deduplicates identical warnings" do
      result = assembler.collect_warnings(
        accumulated: [ "lidar_missing: same" ],
        imagery: { "warnings" => [ "lidar_missing: same" ] },
        refined: { "warnings" => [] },
        geometry: { "warnings" => [] }
      )
      expect(result.count { |w| w == "lidar_missing: same" }).to eq(1)
    end

    it "handles nil warning arrays gracefully" do
      result = assembler.collect_warnings(
        accumulated: [],
        imagery: { "warnings" => nil },
        refined: {},
        geometry: {}
      )
      expect(result).to eq([])
    end
  end

  # ---------------------------------------------------------------------------
  # build_measurement_document
  # ---------------------------------------------------------------------------

  describe "#build_measurement_document" do
    let(:facets) do
      [
        {
          "facet_id" => "F1",
          "vertices" => [ [ -96.702, 40.813 ], [ -96.701, 40.813 ], [ -96.701, 40.814 ] ],
          "pitch_ratio" => 6.0, "pitch_degrees" => 26.57,
          "area_sq_ft" => 712.4, "source" => "fusion", "confidence" => 0.9
        }
      ]
    end

    let(:geometry) do
      {
        "facets" => facets,
        "source" => "fusion",
        "confidence" => 0.9,
        "total_area_sq_ft" => 712.4,
        "primary_pitch_ratio" => 6.0
      }
    end

    it "includes required fields" do
      doc = assembler.build_measurement_document(
        job_id: "abc", footprint: nil, roof_outline: nil,
        lidar: nil, geometry: geometry, features: [], source: "fusion", confidence: 0.9
      )
      expect(doc["job_id"]).to eq("abc")
      expect(doc["facets"]).to eq(facets)
      expect(doc["source"]).to eq("fusion")
      expect(doc["confidence"]).to eq(0.9)
    end

    it "includes total_area_sq_ft from geometry" do
      doc = assembler.build_measurement_document(
        job_id: "abc", footprint: nil, roof_outline: nil,
        lidar: nil, geometry: geometry, features: [], source: "fusion", confidence: 0.9
      )
      expect(doc["total_area_sq_ft"]).to eq(712.4)
    end

    it "maps primary_pitch_ratio to predominant_pitch_ratio" do
      doc = assembler.build_measurement_document(
        job_id: "abc", footprint: nil, roof_outline: nil,
        lidar: nil, geometry: geometry, features: [], source: "fusion", confidence: 0.9
      )
      expect(doc["predominant_pitch_ratio"]).to eq(6.0)
    end

    it "omits footprint key when nil" do
      doc = assembler.build_measurement_document(
        job_id: "abc", footprint: nil, roof_outline: nil,
        lidar: nil, geometry: geometry, features: [], source: "fusion", confidence: 0.9
      )
      expect(doc).not_to have_key("footprint")
    end

    it "includes footprint when present" do
      footprint = { "type" => "Polygon", "coordinates" => [] }
      doc = assembler.build_measurement_document(
        job_id: "abc", footprint: footprint, roof_outline: nil,
        lidar: nil, geometry: geometry, features: [], source: "fusion", confidence: 0.9
      )
      expect(doc["footprint"]).to eq(footprint)
    end
  end

  describe "#build_provenance" do
    it "persists roof-model diagnostics from the geometry response" do
      roof_model = {
        "model_version" => "roof_model_v1",
        "plane_count" => 2,
        "facet_count" => 2,
        "edge_count" => 1,
        "coverage_ratio" => 1.0,
        "area_method" => "outline_clipped_plan_area_div_cos_pitch",
        "boundary_method" => "support_mbr_clipped_to_refined_outline",
        "warnings" => []
      }

      provenance = assembler.build_provenance(
        resolve: { "attribution" => [] },
        imagery: { "attribution" => [] },
        lidar_response: { "attribution" => [], "lidar" => {} },
        refined: { "sam2_backend" => "local" },
        geometry: { "source" => "lidar", "roof_model" => roof_model }
      )

      expect(provenance["roof_model"]).to eq(roof_model)
    end
  end
end
