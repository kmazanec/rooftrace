# Accuracy-validation harness — Rails-side runners (ADR-017 / ADR-006).
#
# The measurement pipeline and the feature detector are Rails-resident
# (app/services/measurement_orchestrator.rb, app/services/feature_detector.rb),
# so the harness's data-producing half MUST run in Ruby. These rake tasks
# produce JSON that the Python half (sidecar/validation/*.py) consumes to compute
# metrics and render docs/VALIDATION_REPORT.md. Keep the language boundary clean:
# Ruby produces measurements + raw detections; Python does math + markdown.
#
# DB hygiene: these tasks create Job + Measurement rows. Run them against a
# dedicated harness database (or a disposable dev DB), NEVER the test DB — see
# sidecar/validation/README.md. The tasks deliberately do NOT clean up rows
# (the cached measurements make re-runs cheap), so do not point them at a DB
# whose contents other specs depend on.

namespace :validation do
  VALIDATION_ROOT = Rails.root.join("sidecar", "validation").freeze
  ADDRESSES_PATH = VALIDATION_ROOT.join("test_addresses.yaml").freeze
  GROUND_TRUTH_PATH = VALIDATION_ROOT.join("ground_truth.yaml").freeze
  RESULTS_DIR = VALIDATION_ROOT.join("results").freeze

  desc "Run the pipeline on each test address and write a results JSON " \
       "(ADDRESS_LIMIT=N for a smoke run; INCLUDE_TODO=1 to run placeholders)"
  task run_measurements: :environment do
    require "yaml"
    require "json"

    addresses = load_addresses
    limit = ENV["ADDRESS_LIMIT"]&.to_i
    include_todo = ENV["INCLUDE_TODO"] == "1"

    addresses = addresses.reject { |a| a["todo"] } unless include_todo
    addresses = addresses.first(limit) if limit&.positive?

    if addresses.empty?
      abort "No addresses to run (all are TODO placeholders? set INCLUDE_TODO=1 " \
            "to run them, or fill real addresses in test_addresses.yaml)."
    end

    results = run_address_batch(addresses)
    path = write_results(results)
    puts "Wrote #{results[:addresses].size} address result(s) to #{path}"
  end

  # --------------------------------------------------------------------------
  # Helpers (defined on the rake DSL object; not registered as tasks).
  # --------------------------------------------------------------------------

  def self.load_addresses
    data = YAML.safe_load_file(ADDRESSES_PATH)
    data.fetch("addresses")
  end

  def self.load_ground_truth
    return {} unless File.exist?(GROUND_TRUTH_PATH)

    gt = YAML.safe_load_file(GROUND_TRUTH_PATH) || {}
    gt.reject { |_k, v| v.is_a?(Hash) && v["todo"] }
  end

  def self.run_address_batch(addresses)
    rows = addresses.map { |entry| run_one(entry) }
    {
      timestamp: Time.now.utc.strftime("%Y-%m-%dT%H-%M-%SZ"),
      # Pipeline-schema version the runner serializes against. Surfaced into the
      # results JSON so the report fails loud on a schema mismatch.
      schema_version: PipelineSchema.version,
      pipeline_version: pipeline_version,
      ground_truth: load_ground_truth,
      addresses: rows
    }
  end

  def self.run_one(entry)
    address = entry.fetch("address")
    base = {
      address: address,
      complexity: entry["complexity"],
      region: entry["region"]
    }
    job = Job.create!(address: address)
    MeasurementOrchestrator.call(job)
    measurement = job.latest_measurement

    if measurement.nil? || job.status == "failed"
      base.merge(measurement: nil, errors: [ job.last_error || "pipeline produced no measurement" ])
    else
      base.merge(measurement: serialize_measurement(measurement))
    end
  rescue StandardError => e
    Rails.logger.error("[validation] #{address} failed: #{e.class}: #{e.message}")
    base.merge(measurement: nil, errors: [ "#{e.class}: #{e.message}" ])
  end

  # Serialize the full Measurement row. predominant_pitch_degrees is DERIVED
  # from the stored ratio (only the ratio is persisted, per the schema contract).
  def self.serialize_measurement(m)
    {
      total_area_sq_ft: m.total_area_sq_ft&.to_f,
      total_perimeter_ft: m.total_perimeter_ft&.to_f,
      predominant_pitch_ratio: m.predominant_pitch_ratio&.to_f,
      predominant_pitch_degrees: ratio_to_degrees(m.predominant_pitch_ratio),
      source: m.source,
      confidence: m.confidence&.to_f,
      warnings: m.warnings,
      facets: m.facets,
      features: m.features,
      lidar: m.lidar,
      geocode: m.geocode,
      parcel_polygon: m.parcel_polygon,
      provenance: m.provenance,
      generated_at: m.generated_at&.iso8601
    }
  end

  # rise/run ratio (per 12) -> degrees. 12/12 == 45 degrees. nil-safe.
  def self.ratio_to_degrees(ratio)
    return nil if ratio.nil?

    Math.atan(ratio.to_f / 12.0) * 180.0 / Math::PI
  end

  def self.pipeline_version
    ENV["PIPELINE_VERSION"] || `git rev-parse --short HEAD 2>/dev/null`.strip.presence || "unknown"
  end

  def self.write_results(results)
    FileUtils.mkdir_p(RESULTS_DIR)
    path = RESULTS_DIR.join("#{results[:timestamp]}.json")
    File.write(path, JSON.pretty_generate(results))
    path
  end
end
