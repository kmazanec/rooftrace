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

  FD_ROOT = VALIDATION_ROOT.join("feature_detection").freeze
  FD_LABELS_PATH = FD_ROOT.join("labels.json").freeze
  # Cross-architecture candidate sweep (ADR-006). Both slugs are reachable
  # through the OpenRouter backend by changing one model string; override with
  # CANDIDATE_MODELS (comma-separated) for a different sweep.
  DEFAULT_CANDIDATE_MODELS = %w[
    google/gemini-2.5-flash
    qwen/qwen2.5-vl-72b-instruct
  ].freeze
  # Eval tiles are uploaded under the cache/ prefix so ImageryUrlMinter (locked
  # to cache/) can mint a signed Spaces URL the detector's host allowlist
  # accepts — no SSRF-allowlist widening (ADR-006 / ADR-010).
  FD_TILE_KEY_PREFIX = "cache/validation/feature_detection/".freeze

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

  desc "Run each candidate feature-detection model over the labeled tiles and " \
       "write predictions_<slug>.json (CANDIDATE_MODELS=slug,slug to override)"
  task eval_features: :environment do
    require "json"

    labels = JSON.parse(File.read(FD_LABELS_PATH)).fetch("tiles")
    labels = labels.reject { |_id, t| t["seed"] } if ENV["SKIP_SEED_TILES"] == "1"
    candidate_models.each do |slug|
      predictions = eval_one_model(slug, labels)
      path = write_predictions(slug, predictions)
      puts "Wrote #{predictions['tiles'].size} tile prediction(s) for #{slug} to #{path}"
    end
  end

  # --------------------------------------------------------------------------
  # Helpers (defined on the rake DSL object; not registered as tasks).
  # --------------------------------------------------------------------------

  def self.candidate_models
    raw = ENV["CANDIDATE_MODELS"].to_s.strip
    return DEFAULT_CANDIDATE_MODELS if raw.empty?

    raw.split(",").map(&:strip).reject(&:empty?)
  end

  # Run one candidate model over every labeled tile. Each tile is uploaded under
  # the cache/ prefix and served to the detector via a signed Spaces URL, so the
  # detector's host allowlist is satisfied without widening it.
  def self.eval_one_model(slug, labels)
    detector = FeatureDetector::OpenRouter.new(model: slug)
    tiles = labels.each_with_object({}) do |(tile_id, tile), acc|
      acc[tile_id] = detect_tile(detector, tile_id, tile)
    rescue StandardError => e
      # Record the failure explicitly rather than as an empty detection array:
      # an empty array is a legitimate true-negative prediction, and conflating
      # an upload/detection error with one would silently inflate the model's
      # miss rate (every GT box on the tile becomes a phantom FN). The scorer
      # (eval_models.score_model) skips tiles whose prediction entry is not an
      # Array and reports them as excluded.
      Rails.logger.error("[validation] #{slug} on #{tile_id} failed: #{e.class}: #{e.message}")
      acc[tile_id] = { "error" => "#{e.class}: #{e.message}" }
    end
    { "model" => slug, "tiles" => tiles }
  end

  def self.detect_tile(detector, tile_id, tile)
    image_path = FD_ROOT.join(tile.fetch("image_path"))
    url = upload_and_sign(tile_id, image_path)
    detector.detect(image_tile_url: url, roof_polygon: tile["roof_polygon"] || full_tile_polygon)
  end

  # Upload the tile bytes to the cache/ prefix and return a signed GET URL.
  def self.upload_and_sign(tile_id, image_path)
    key = "#{FD_TILE_KEY_PREFIX}#{tile_id}.png"
    spaces_client.put_object(
      bucket: ENV.fetch("STORAGE_BUCKET", "rooftrace"),
      key: key,
      body: File.binread(image_path),
      content_type: "image/png"
    )
    ImageryUrlMinter.call(object_key: key, expires_in: 1.hour)
  end

  def self.spaces_client
    Aws::S3::Client.new(
      access_key_id: ENV.fetch("STORAGE_ACCESS_KEY"),
      secret_access_key: ENV.fetch("STORAGE_SECRET_KEY"),
      endpoint: ENV.fetch("STORAGE_ENDPOINT"),
      region: ENV.fetch("STORAGE_REGION", "us-east-1"),
      force_path_style: false
    )
  end

  # A unit-square WGS84 polygon stand-in when a tile has no roof polygon: the
  # detector needs a polygon arg but the eval scores image-space bboxes.
  def self.full_tile_polygon
    { "coordinates" => [ [ [ 0.0, 0.0 ], [ 0.0, 1.0 ], [ 1.0, 1.0 ], [ 1.0, 0.0 ], [ 0.0, 0.0 ] ] ] }
  end

  def self.write_predictions(slug, predictions)
    path = FD_ROOT.join("predictions_#{slug.tr('/', '_')}.json")
    File.write(path, JSON.pretty_generate(predictions))
    path
  end

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
    base = nil
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
    # `base` is nil if the failure happened before it was assigned (e.g. a
    # malformed entry with no "address" key raising KeyError on fetch). Fall
    # back to a minimal base so the malformed entry is recorded as an error and
    # the batch continues, rather than nil.merge raising a fresh NoMethodError
    # that escapes the rescue and aborts the whole batch.
    address = base&.dig(:address) || entry.inspect
    Rails.logger.error("[validation] #{address} failed: #{e.class}: #{e.message}")
    (base || { address: entry.inspect, complexity: nil, region: nil })
      .merge(measurement: nil, errors: [ "#{e.class}: #{e.message}" ])
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
