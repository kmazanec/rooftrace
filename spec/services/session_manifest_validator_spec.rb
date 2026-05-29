require "rails_helper"

# SessionManifestValidator unit tests. The validator is the trust boundary for an
# iOS capture bundle (ADR-007): a malformed manifest must be a clean 400, never a
# downstream TypeError/500 or a corrupt session.
RSpec.describe SessionManifestValidator, type: :service do
  def base_manifest
    {
      "manifest_version" => "1.0.0",
      "session_id" => "5e551011-0000-4000-8000-000000000001",
      "job_id" => "synthetic-job-0001",
      "gps_origin" => {
        "latitude" => 40.81357,
        "longitude" => -96.70258,
        "altitude_m" => 360.0,
        "horizontal_accuracy_m" => 3.5,
        "vertical_accuracy_m" => 5.0
      },
      "world_mesh" => { "filename" => "arkit_mesh.obj", "format" => "obj" },
      "captures" => [
        { "capture_index" => 0, "prompt_label" => "Northeast corner", "timestamp" => "2025-01-15T14:30:05Z" },
        { "capture_index" => 1, "prompt_label" => "Southeast corner", "timestamp" => "2025-01-15T14:30:10Z" }
      ]
    }
  end

  def errors_for(manifest)
    described_class.call(manifest)[:errors]
  end

  it "accepts a well-formed manifest" do
    result = described_class.call(base_manifest)
    expect(result[:valid]).to be(true)
    expect(result[:errors]).to be_empty
  end

  describe "per-capture validation" do
    it "is invalid when a capture is missing capture_index" do
      m = base_manifest
      m["captures"][0].delete("capture_index")
      expect(errors_for(m).join).to match(/capture_index must be an integer/)
    end

    it "is invalid when capture_index is non-integer" do
      m = base_manifest
      m["captures"][0]["capture_index"] = "zero"
      expect(errors_for(m).join).to match(/capture_index must be an integer/)
    end

    it "is invalid when capture_index is out of range" do
      m = base_manifest
      m["captures"][0]["capture_index"] = 99
      expect(errors_for(m).join).to match(/capture_index must be an integer in 0\.\.7/)
    end

    it "is invalid when capture_index values are duplicated" do
      m = base_manifest
      m["captures"][1]["capture_index"] = 0
      expect(errors_for(m).join).to match(/duplicate capture_index 0/)
    end

    it "is invalid when a capture is missing prompt_label" do
      m = base_manifest
      m["captures"][0].delete("prompt_label")
      expect(errors_for(m).join).to match(/prompt_label is required/)
    end

    it "is invalid when a capture is missing timestamp" do
      m = base_manifest
      m["captures"][0].delete("timestamp")
      expect(errors_for(m).join).to match(/timestamp is required/)
    end

    it "is invalid when a capture entry is not an object" do
      m = base_manifest
      m["captures"][0] = "nope"
      expect(errors_for(m).join).to match(/must be an object/)
    end
  end

  it "still rejects an empty captures array" do
    m = base_manifest
    m["captures"] = []
    expect(errors_for(m).join).to match(/non-empty array/)
  end
end
