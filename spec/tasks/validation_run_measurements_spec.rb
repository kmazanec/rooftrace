# Exercises the Rails-side measurement runner (lib/tasks/validation.rake) with a
# stubbed orchestrator against the real DB, so the runner's wiring (Job creation,
# measurement serialization incl. DERIVED pitch_degrees, results-JSON shape,
# error capture) is verified without live Modal/OpenRouter credentials. A full
# live run is manual-smoke only (cost + creds), per ADR-017.
require "rails_helper"
require "rake"

RSpec.describe "validation:run_measurements", type: :task do
  before(:all) do
    Rake.application.rake_require("tasks/validation", [ Rails.root.join("lib").to_s ])
    Rake::Task.define_task(:environment)
  end

  let(:task) { Rake::Task["validation:run_measurements"] }
  let(:results_dir) { Rails.root.join("sidecar", "validation", "results") }

  around do |example|
    existing = Dir.children(results_dir).reject { |f| f == ".gitkeep" }
    example.run
    # Clean only the JSON this example wrote, never .gitkeep or pre-existing files.
    (Dir.children(results_dir).reject { |f| f == ".gitkeep" } - existing).each do |f|
      File.delete(results_dir.join(f))
    end
  end

  after { task.reenable }

  def latest_results_json
    files = Dir.children(results_dir).select { |f| f.end_with?(".json") }
    JSON.parse(File.read(results_dir.join(files.max)))
  end

  it "creates a Job per address, runs the orchestrator, and serializes the measurement" do
    allow(MeasurementOrchestrator).to receive(:call) do |job|
      create(
        :measurement,
        job: job,
        total_area_sq_ft: 2000.0,
        predominant_pitch_ratio: 12.0, # 12/12 == 45 degrees, a sharp known answer
        total_perimeter_ft: 180.0,
        source: "fusion",
        confidence: 0.85,
        facets: [ { "facet_id" => "f1", "pitch_degrees" => 26.6, "source" => "lidar", "confidence" => 0.9 } ],
        features: [ { "label" => "chimney", "bbox_norm" => [ 0.1, 0.1, 0.2, 0.2 ], "verified" => true, "source" => "imagery", "confidence" => 0.8 } ]
      )
      job.advance_to!(:ready, broadcast: false)
    end

    expect { task.invoke }.to change(Job, :count).by(1)

    data = latest_results_json
    expect(data["schema_version"]).to eq(PipelineSchema.version)
    row = data["addresses"].first
    expect(row["measurement"]["total_area_sq_ft"]).to eq(2000.0)
    expect(row["measurement"]["source"]).to eq("fusion")
    # predominant_pitch_degrees is DERIVED from the ratio (12/12 -> 45 deg).
    expect(row["measurement"]["predominant_pitch_degrees"]).to be_within(0.01).of(45.0)
    expect(row["measurement"]["facets"].first["facet_id"]).to eq("f1")
  end

  it "captures a per-address error and continues when the pipeline fails" do
    allow(MeasurementOrchestrator).to receive(:call) do |job|
      job.fail_with!("LiDAR work unit not found")
      nil
    end

    task.invoke
    row = latest_results_json["addresses"].first
    expect(row["measurement"]).to be_nil
    expect(row["errors"]).to include(a_string_matching(/LiDAR work unit not found/))
  end

  it "records a malformed entry (missing 'address' key) as an error and finishes the batch" do
    addresses_path = Rails.root.join("sidecar", "validation", "test_addresses.yaml")
    # First entry is malformed (no "address"); second is well-formed. The bad
    # entry must be recorded as an error WITHOUT aborting the whole batch
    # (regression: the run_one rescue used to call nil.merge on the bad entry,
    # raising a fresh NoMethodError that escaped the rescue and crashed the run).
    allow(YAML).to receive(:safe_load_file).and_call_original
    allow(YAML).to receive(:safe_load_file).with(addresses_path).and_return(
      "addresses" => [
        { "complexity" => "simple", "region" => "NE" }, # no "address"
        { "address" => "1 Good St", "complexity" => "simple", "region" => "NE" }
      ]
    )
    allow(MeasurementOrchestrator).to receive(:call) do |job|
      create(:measurement, job: job, total_area_sq_ft: 100.0)
      job.advance_to!(:ready, broadcast: false)
    end

    expect { task.invoke }.not_to raise_error

    rows = latest_results_json["addresses"]
    expect(rows.size).to eq(2)
    bad = rows.find { |r| r["measurement"].nil? }
    expect(bad["errors"]).to include(a_string_matching(/KeyError/))
    good = rows.find { |r| r["address"] == "1 Good St" }
    expect(good["measurement"]["total_area_sq_ft"]).to eq(100.0)
  end

  it "respects ADDRESS_LIMIT and INCLUDE_TODO for a smoke run" do
    allow(MeasurementOrchestrator).to receive(:call) do |job|
      create(:measurement, job: job, total_area_sq_ft: 1.0)
      job.advance_to!(:ready, broadcast: false)
    end

    ENV["ADDRESS_LIMIT"] = "2"
    ENV["INCLUDE_TODO"] = "1" # include placeholders so the limit has >1 to bite
    task.invoke
    expect(latest_results_json["addresses"].size).to eq(2)
  ensure
    ENV.delete("ADDRESS_LIMIT")
    ENV.delete("INCLUDE_TODO")
  end
end
