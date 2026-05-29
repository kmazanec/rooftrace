# Chains the geospatial pipeline stages into one persisted Measurement.
#
# The orchestrator owns the Rails-side composition of the per-stage sidecar
# calls (resolve-address -> render-imagery -> ingest-lidar -> refine-outline ->
# fit-planes | fallback-measurement) plus the Rails-resident VLM feature
# detector, and folds their outputs into the unified Measurement contract entity
# before persisting it (ADR-008: Rails owns orchestration/persistence; the
# sidecar owns geometry).
#
# Key behaviours:
#   * Status is advanced (and broadcast) at each stage boundary so the status
#     page live-updates.
#   * The VLM runs in a separate thread, concurrent with the geometric stages,
#     and is failure-isolated: a VLM failure yields features:[] + a warning, the
#     measurement still completes. A geometric failure fails the whole job
#     (no geometry == no measurement).
#   * Every cross-service payload is schema-validated by SidecarClient; a
#     SchemaError is re-surfaced as a loud job failure naming the offending stage.
#   * The assembled Measurement is itself validated against the Measurement
#     schema entity before persistence (catches Rails-side composition drift).
#   * Idempotent: a measurement for the same address+polygon_selection generated
#     within the last hour is reused instead of re-running the pipeline.
class MeasurementOrchestrator
  # Stage names used in error messages so a failure points at the drifted stage.
  STAGE_LABELS = {
    "ResolveAddressResponse" => "resolve-address",
    "RenderImageryResponse" => "render-imagery",
    "IngestLidarResponse" => "ingest-lidar",
    "RefineOutlineResponse" => "refine-outline",
    "MeasurementGeometry" => "fit-planes/fallback-measurement"
  }.freeze

  # Geometry stages are slow (network + numerics); override the client's short
  # default per-call timeout generously.
  STAGE_TIMEOUT_SECONDS = 90

  # Tile edge size we ask the imagery stage to render. Big enough for SAM2 +
  # the VLM to work with, small enough to stay within a NAIP tile.
  IMAGERY_SIZE_PX = 1024

  # How long the geometric chain will wait for the parallel VLM thread to finish
  # once geometry is done. Past this the VLM is abandoned (features:[]+warning)
  # rather than blocking the measurement.
  VLM_JOIN_TIMEOUT_SECONDS = 60

  # Idempotency window: a re-submission for the same address+polygon_selection
  # within this window reuses the cached measurement.
  IDEMPOTENCY_WINDOW = 1.hour

  # Default UTM-zone fallback handling: on the LiDAR-missing path the sidecar
  # never told us a UTM zone (it only returns one with points). We derive an
  # EPSG code from the geocoded longitude/latitude so the fallback measurement
  # can compute planimetric area in a sensible local projection.
  class GeometricFailure < StandardError; end

  def self.call(job)
    new(job).call
  end

  def initialize(job, sidecar: SidecarClient, detector_factory: FeatureDetector,
                 url_minter: ImageryUrlMinter, logger: Rails.logger)
    @job = job
    @sidecar = sidecar
    @detector_factory = detector_factory
    @url_minter = url_minter
    @logger = logger
    @warnings = []
    # The VLM thread and the main thread both append warnings; guard the buffer.
    @warnings_mutex = Mutex.new
  end

  # Run the chain and return the persisted Measurement (or the cached one).
  # Raises nothing for expected failure modes — it transitions the Job to
  # `failed` via fail_with! and returns nil so GeometryJob need not distinguish.
  def call
    cached = cached_measurement
    return cached if cached

    run_pipeline
  rescue SidecarClient::SchemaError => e
    @job.fail_with!("Pipeline contract violation at #{offending_stage(e)}: #{e.message}")
    nil
  rescue GeometricFailure => e
    @job.fail_with!(e.message)
    nil
  rescue SidecarClient::TimeoutError => e
    @job.fail_with!("A pipeline stage timed out: #{e.message}")
    nil
  rescue SidecarClient::Error => e
    @job.fail_with!("Pipeline stage failed: #{e.message}")
    nil
  end

  private

  attr_reader :job

  # Append a warning under the mutex — the parallel VLM thread and the main
  # thread both write to @warnings.
  def add_warning(message)
    @warnings_mutex.synchronize { @warnings << message }
  end

  # --------------------------------------------------------------------------
  # Idempotency
  # --------------------------------------------------------------------------

  # The dedupe key is address + polygon_selection (the two inputs that fully
  # determine the pipeline output). A measurement generated within the window
  # for the same job is reused ONLY when its stored input fingerprint still
  # matches the job's current address+polygon_selection — a Job can be reused
  # after an address/selection edit, and reusing a measurement built from the
  # old inputs would serve a stale result. We scope by job since a Measurement
  # belongs_to a job and a re-submission is, in this model, a re-run of the same
  # Job record.
  def cached_measurement
    recent = job.latest_measurement
    return nil if recent.nil?
    return nil if recent.generated_at.nil?
    return nil if recent.generated_at < IDEMPOTENCY_WINDOW.ago
    return nil unless recent.source_fingerprint == current_fingerprint

    @logger.info("[MeasurementOrchestrator] reusing measurement #{recent.id} " \
                 "(generated #{recent.generated_at.iso8601}) for job #{job.id}")
    # If the job is stuck mid-pipeline (e.g. a prior run created the measurement
    # but crashed before advancing to :ready), the cache serving the result must
    # also move the status to :ready so the status page reflects the available
    # measurement instead of staying stuck. A job already :ready is left alone; a
    # :failed job is terminal and advance_to! would (correctly) refuse, so we
    # only advance from a non-terminal, non-ready status.
    unless job.ready?
      job.advance_to!(:ready) unless job.terminal?
    end
    recent
  end

  # A stable digest of the inputs that fully determine the pipeline output. Any
  # change to the address or the selected building polygon yields a different
  # fingerprint, so a cached measurement built from prior inputs is not reused.
  def current_fingerprint
    # Memoized - computed in both cached_measurement and persist within one run.
    # Length-prefix each field so the join is unambiguous regardless of field
    # contents (an address can itself contain any separator char, including a
    # pipe), and use only printable ASCII (no control/NUL bytes in source).
    @current_fingerprint ||= begin
      address = job.address.to_s
      selection = job.polygon_selection.to_s
      Digest::SHA256.hexdigest("#{address.length}:#{address}|#{selection.length}:#{selection}")
    end
  end

  # --------------------------------------------------------------------------
  # The chain
  # --------------------------------------------------------------------------

  def run_pipeline
    run_pipeline_stages
  ensure
    # The VLM thread is spawned early (start_vlm) and concurrent with the slow
    # geometric stages. If a later geometric stage raises, the rescues in `call`
    # transition the job to failed but the detector thread would otherwise keep
    # doing external API work against an already-failed job (and repeated
    # failures would accumulate threads). Always clean it up on ANY exit —
    # success OR exception — before propagating. On the happy path join_vlm has
    # already consumed it, so this is a no-op there.
    cleanup_vlm_thread
  end

  def run_pipeline_stages
    # A cache miss on a previously-terminal Job is an intentional re-run (an
    # address/selection edit invalidated the cached measurement). Reset the
    # status out of terminal here so the stage progression can advance again —
    # advance_to!'s terminal guard only blocks UNintended resurrection (a stray
    # duplicate run), not this explicit re-run.
    job.update!(status: "pending") if job.terminal?

    resolve = resolve_address_stage
    building_polygon = pick_building_polygon(resolve)

    imagery = imagery_stage(building_polygon)
    image_tile_ref = imagery.fetch("image_tile_ref")
    image_geo_bounds = imagery.fetch("image_geo_bounds")

    # Kick off the VLM in parallel with the geometric stages. It detects against
    # the just-rendered tile and the building polygon prior (the refined outline
    # is not yet available; the tile + footprint are enough for bbox detection).
    vlm = start_vlm(image_tile_ref: image_tile_ref, roof_polygon: building_polygon)

    lidar_response = lidar_stage(building_polygon, resolve_parcel(resolve))
    refined = refine_stage(image_tile_ref:, prior_polygon: building_polygon, image_geo_bounds:)
    refined_polygon = refined.fetch("refined_polygon")

    geometry, source =
      if lidar_available?(lidar_response)
        [ fit_planes_stage(lidar_response, refined_polygon), "fusion" ]
      else
        note_lidar_missing(lidar_response)
        [ fallback_stage(refined_polygon, resolve, lidar_response), "imagery" ]
      end
    guard_facets!(geometry)

    features = join_vlm(vlm)

    assemble_and_persist(
      resolve:, building_polygon:, imagery:, lidar_response:,
      refined:, refined_polygon:, geometry:, source:, features:
    )
  end

  def resolve_address_stage
    job.advance_to!(:resolving_address)
    @sidecar.resolve_address(address: job.address, timeout: STAGE_TIMEOUT_SECONDS)
  end

  def pick_building_polygon(resolve)
    polygons = Array(resolve["building_polygons"])
    raise GeometricFailure, "No building footprint found for this address." if polygons.empty?

    index = job.polygon_selection.to_i
    index = 0 if index.negative? || index >= polygons.length
    polygons[index]
  end

  def resolve_parcel(resolve)
    resolve["parcel_polygon"]
  end

  def imagery_stage(building_polygon)
    job.advance_to!(:fetching_imagery)
    @sidecar.render_imagery(
      building_polygon: building_polygon,
      size_px: IMAGERY_SIZE_PX,
      timeout: STAGE_TIMEOUT_SECONDS
    )
  end

  # ADR-001: a LiDAR problem must DEGRADE to the imagery-only path, not fail the
  # whole job. A transport/5xx/timeout error from THIS stage is mapped to a
  # synthetic LIDAR_MISSING outcome so the existing fallback path proceeds
  # (source: imagery, lower confidence). A SchemaError is deliberately NOT caught
  # here: a contract violation is a bug to surface loudly, not a soft miss, so it
  # bubbles to the top rescue and hard-fails the job.
  def lidar_stage(building_polygon, parcel_polygon)
    job.advance_to!(:fetching_lidar)
    @sidecar.ingest_lidar(
      building_polygon: building_polygon,
      parcel_polygon: parcel_polygon,
      timeout: STAGE_TIMEOUT_SECONDS
    )
  rescue SidecarClient::SchemaError
    raise
  rescue SidecarClient::Error => e
    # SidecarClient::TimeoutError is an Error subclass, so both transport and
    # timeout failures degrade here; SchemaError was re-raised above.
    synthetic_lidar_missing(e)
  end

  # A LIDAR_MISSING-shaped response standing in for an ingest-lidar transport
  # failure, marked so note_lidar_missing records the transport cause verbatim
  # ("lidar_unavailable: <class>") rather than the generic no-coverage warning.
  def synthetic_lidar_missing(error)
    {
      "lidar" => { "status" => "LIDAR_MISSING" },
      "warnings" => [ "lidar_unavailable: #{error.class}" ],
      "degraded" => true
    }
  end

  def refine_stage(image_tile_ref:, prior_polygon:, image_geo_bounds:)
    job.advance_to!(:refining_outline)
    @sidecar.refine_outline(
      image_tile_ref: image_tile_ref,
      prior_polygon: prior_polygon,
      image_geo_bounds: image_geo_bounds,
      timeout: STAGE_TIMEOUT_SECONDS
    )
  end

  def fit_planes_stage(lidar_response, refined_polygon)
    job.advance_to!(:fitting_planes)
    lidar = lidar_response.fetch("lidar")
    @sidecar.fit_planes(
      point_array_ref: lidar.fetch("point_array_ref"),
      utm_zone: lidar_response.fetch("utm_zone"),
      refined_polygon: refined_polygon,
      timeout: STAGE_TIMEOUT_SECONDS
    )
  end

  # No-LiDAR fallback. The sidecar never supplied a utm_zone here (it only
  # returns one alongside points), so we derive a sensible local UTM EPSG code
  # from the geocoded lon/lat. We also infer a pitch the heuristic way: a
  # typical residential 6/12 (~26.57 deg) when nothing better is known. The
  # sidecar's fallback divides planimetric area by cos(pitch).
  DEFAULT_INFERRED_PITCH_DEGREES = 26.57

  def fallback_stage(refined_polygon, resolve, _lidar_response)
    job.advance_to!(:fitting_planes)
    @sidecar.fallback_measurement(
      refined_polygon: refined_polygon,
      inferred_pitch_degrees: DEFAULT_INFERRED_PITCH_DEGREES,
      utm_zone: derive_utm_epsg(resolve),
      timeout: STAGE_TIMEOUT_SECONDS
    )
  end

  # A roof with no facets (sparse LiDAR / degenerate outline) is not a usable
  # measurement. Treat empty facets on EITHER path as a geometric failure rather
  # than persisting a "complete" measurement with zero facets and area 0.
  def guard_facets!(geometry)
    return unless Array(geometry["facets"]).empty?

    raise GeometricFailure,
          "No roof facets could be measured for this address " \
          "(the roof outline produced no usable surfaces)."
  end

  def lidar_available?(lidar_response)
    lidar_response.dig("lidar", "status") == "LIDAR_AVAILABLE"
  end

  def note_lidar_missing(lidar_response)
    # A degraded (transport-failure) response already carries its own
    # "lidar_unavailable: <class>" warning — record that verbatim (ADR-001).
    if lidar_response["degraded"]
      add_warning(Array(lidar_response["warnings"]).first)
      return
    end

    reason = Array(lidar_response["warnings"]).first ||
             lidar_response.dig("lidar", "status") ||
             "no 3DEP coverage"
    add_warning("lidar_missing: #{reason}")
  end

  # Derive a Northern-Hemisphere UTM EPSG code (326xx) from the geocoded
  # longitude. WGS84/UTM north codes are 32600 + zone_number; RoofTrace's
  # footprint is the US, so the northern-hemisphere assumption holds for the
  # served addresses. A nil/absent lon must NOT default to a CONUS-center zone:
  # the fallback path needs a real zone to compute planimetric area, and a wrong
  # zone produces a silently-wrong area — worse than failing — so we fail clean.
  def derive_utm_epsg(resolve)
    lon = resolve.dig("geocode", "lon")
    if lon.nil?
      raise GeometricFailure,
            "Could not determine a map projection for this location " \
            "(no longitude from geocoding), so the roof area can't be computed."
    end

    zone = (((lon.to_f + 180.0) / 6.0).floor + 1).clamp(1, 60)
    32_600 + zone
  end

  # --------------------------------------------------------------------------
  # VLM (parallel, failure-isolated)
  # --------------------------------------------------------------------------

  # Broadcast the conceptual feature-detection stage and spawn the VLM thread.
  # The detector fetches the tile via a short-lived signed URL we mint over our
  # own Spaces object (SSRF-safe — see ImageryUrlMinter). A failure inside the
  # thread is captured, not raised, so it can't take down the geometric chain;
  # join_vlm turns it into features:[] + a warning.
  def start_vlm(image_tile_ref:, roof_polygon:)
    job.advance_to!(:detecting_features)
    # Hold the thread on an ivar so run_pipeline's ensure can clean it up if a
    # later geometric stage raises before join_vlm consumes it.
    @vlm_thread = Thread.new do
      image_tile_url = @url_minter.call(object_key: image_tile_ref)
      features = @detector_factory.build.detect(
        image_tile_url: image_tile_url,
        roof_polygon: roof_polygon
      )
      { features: Array(features) }
    rescue StandardError => e
      { error: "#{e.class}: #{e.message}" }
    end
  end

  # Grace period given to a timed-out VLM thread to unwind on its own before we
  # kill it. Gemini's client carries its own 30s open/read timeout, so a bare
  # immediate kill can sever the socket mid-request and leak it; we log, treat
  # the detection as failed (features:[]), and let the thread finish cleanly
  # within the grace before falling back to a kill.
  VLM_JOIN_GRACE_SECONDS = 5

  def join_vlm(thread)
    # The happy path consumes the thread here; clear the ivar so run_pipeline's
    # ensure-time cleanup is a no-op (it only kills a thread still in flight
    # because a geometric stage raised before we got here).
    @vlm_thread = nil
    result = thread.join(VLM_JOIN_TIMEOUT_SECONDS)&.value
    if result.nil?
      @logger.warn("[MeasurementOrchestrator] VLM detection timed out after " \
                   "#{VLM_JOIN_TIMEOUT_SECONDS}s; abandoning (features:[])")
      thread.kill unless thread.join(VLM_JOIN_GRACE_SECONDS)
      add_warning("vlm_failed: detection timed out after #{VLM_JOIN_TIMEOUT_SECONDS}s")
      return []
    end
    if result[:error]
      add_warning("vlm_failed: #{result[:error]}")
      return []
    end
    result[:features]
  end

  # Kill/join the VLM thread if it is still alive when run_pipeline exits for any
  # reason. Reuses join_vlm's grace-then-kill discipline (a bare immediate kill
  # can sever Gemini's socket mid-request). A nil ivar means join_vlm already
  # consumed it (happy path) or the thread never started (early failure).
  def cleanup_vlm_thread
    thread = @vlm_thread
    @vlm_thread = nil
    return if thread.nil?
    return unless thread.alive?

    @logger.warn("[MeasurementOrchestrator] cleaning up in-flight VLM thread " \
                 "after pipeline exited early (job #{job.id})")
    thread.kill unless thread.join(VLM_JOIN_GRACE_SECONDS)
  end

  # --------------------------------------------------------------------------
  # Assembly + persistence
  # --------------------------------------------------------------------------

  def assemble_and_persist(resolve:, building_polygon:, imagery:, lidar_response:,
                           refined:, refined_polygon:, geometry:, source:, features:)
    warnings = collect_warnings(imagery:, refined:, geometry:)
    confidence = overall_confidence(resolve:, geometry:, lidar_available: source == "fusion")
    measurement_doc = build_measurement_document(
      footprint: building_polygon, roof_outline: refined_polygon,
      lidar: lidar_response["lidar"], geometry:, features:, source:, confidence:
    )

    validate_measurement!(measurement_doc)

    provenance = build_provenance(resolve:, imagery:, lidar_response:, refined:, geometry:)
    persist(
      measurement_doc, provenance:, warnings:,
      total_perimeter_ft: geometry["total_perimeter_ft"],
      geocode: resolve["geocode"],
      parcel_polygon: resolve_parcel(resolve)
    )
  end

  # Assemble the schema `Measurement` entity (the cross-service contract shape).
  # job_id + facets + features + source + confidence are required; the polygons
  # and roll-ups are optional and included when present.
  def build_measurement_document(footprint:, roof_outline:, lidar:, geometry:,
                                  features:, source:, confidence:)
    doc = {
      "job_id" => job.id,
      "facets" => Array(geometry["facets"]),
      "features" => Array(features),
      "source" => source,
      "confidence" => confidence
    }
    doc["footprint"] = footprint if footprint
    doc["roof_outline"] = roof_outline if roof_outline
    doc["lidar"] = lidar if lidar
    unless geometry["total_area_sq_ft"].nil?
      doc["total_area_sq_ft"] = geometry["total_area_sq_ft"]
    end
    unless geometry["primary_pitch_ratio"].nil?
      doc["predominant_pitch_ratio"] = geometry["primary_pitch_ratio"]
    end
    doc
  end

  # The assembled Measurement is a cross-service contract entity; validating it
  # before persistence catches Rails-side composition drift (e.g. a stage shape
  # that changed under us) loudly rather than writing a malformed row.
  def validate_measurement!(doc)
    errors = PipelineSchema.errors_for("Measurement", doc)
    return if errors.empty?

    raise SidecarClient::SchemaError,
          "Measurement assembly validation failed (contract drift?): #{errors.join('; ')}"
  end

  # `doc` is the schema-validated Measurement contract entity (its keys are
  # constrained by the schema's additionalProperties:false). The remaining
  # keyword args are row-only columns that downstream consumers need but that
  # are not part of that validated contract shape, so they're persisted directly
  # on the row rather than threaded through the validated document.
  def persist(doc, provenance:, warnings:, total_perimeter_ft:, geocode:, parcel_polygon:)
    # Create the Measurement and flip the job to :ready in ONE transaction so they
    # commit together. Otherwise, if advance_to! raised after create!, a
    # Measurement would exist while the job stayed mid-pipeline — and a later run
    # would hit the idempotency cache and return that measurement without the job
    # ever reaching :ready. The Turbo broadcast is deferred until AFTER commit so
    # an ActionCable publish is never held inside the open transaction.
    measurement = nil
    job.transaction do
      measurement = job.measurements.create!(
        footprint: doc["footprint"],
        roof_outline: doc["roof_outline"],
        lidar: doc["lidar"],
        facets: doc["facets"],
        features: doc["features"],
        total_area_sq_ft: doc["total_area_sq_ft"],
        predominant_pitch_ratio: doc["predominant_pitch_ratio"],
        source: doc["source"],
        confidence: doc["confidence"],
        warnings: warnings,
        provenance: provenance,
        total_perimeter_ft: total_perimeter_ft,
        geocode: geocode,
        parcel_polygon: parcel_polygon,
        source_fingerprint: current_fingerprint,
        generated_at: Time.current
      )
      job.advance_to!(:ready, broadcast: false)
    end
    # A ready job always has a shareable Report (ADR-016: the share token IS the
    # access grant for /r/:token; the public viewer/PDF/JSON surfaces resolve a
    # job through its Report's share_token). Mint it AFTER the measurement
    # transaction commits, NOT inside it: a concurrent creator (a contractor
    # opening /jobs/:id/report at the same instant) racing the unique index on
    # reports.job_id would raise RecordNotUnique and roll back the whole
    # transaction — discarding the Measurement + :ready flip even though the
    # pipeline succeeded. ensure_report_for is race-safe; a post-commit hiccup
    # here cannot lose the measurement.
    ensure_report_for(job)
    job.broadcast_status!
    measurement
  end

  # Idempotent, concurrency-safe Report mint. find_or_create_by can still lose
  # the SELECT-then-INSERT race under the unique index on reports.job_id; the
  # loser rescues RecordNotUnique and returns the winner's row. Shared
  # convention with JobsController#report (ADR-016).
  def ensure_report_for(job)
    Report.find_or_create_by!(job: job)
  rescue ActiveRecord::RecordNotUnique
    Report.find_by!(job: job)
  end

  # --------------------------------------------------------------------------
  # Confidence + warnings + provenance
  # --------------------------------------------------------------------------

  # Overall confidence is the product of the stage confidences we have
  # (geocode * geometry), so any weak stage drags the whole number down —
  # honest-uncertainty rule. The fallback (imagery-only) path additionally caps
  # the result so an imagery-only measurement can never read as confident as a
  # fused one even if the individual stages were optimistic.
  IMAGERY_CONFIDENCE_CAP = 0.6

  def overall_confidence(resolve:, geometry:, lidar_available:)
    geocode_conf = resolve.dig("geocode", "confidence")
    geometry_conf = geometry["confidence"]
    factors = [ geocode_conf, geometry_conf ].compact.map(&:to_f)
    combined = factors.empty? ? 0.0 : factors.inject(:*)
    combined = [ combined, IMAGERY_CONFIDENCE_CAP ].min unless lidar_available
    combined.clamp(0.0, 1.0).round(4)
  end

  def collect_warnings(imagery:, refined:, geometry:)
    (@warnings +
      Array(imagery["warnings"]) +
      Array(refined["warnings"]) +
      Array(geometry["warnings"])).uniq
  end

  # Provenance records the data-source attributions each stage returned, the
  # detector identity, and the schema version, so downstream surfaces can render
  # the attribution the data licenses require. It also captures the acquisition
  # vintage of the source data (LiDAR work-unit year/quality-level and the
  # per-stage retrieved_at timestamps) so a report can state how current the
  # underlying data is.
  def build_provenance(resolve:, imagery:, lidar_response:, refined:, geometry:)
    {
      "pipeline_schema_version" => PipelineSchema.version,
      "detector" => FeatureDetector::DETECTOR_NAME,
      "sam2_backend" => refined["sam2_backend"],
      "geometry_source" => geometry["source"],
      "lidar_work_unit" => lidar_work_unit(lidar_response),
      "attributions" => {
        "resolve_address" => resolve["attribution"],
        "imagery" => imagery["attribution"],
        "lidar" => lidar_response["attribution"]
      }.compact,
      "retrieved_at" => {
        "resolve_address" => first_retrieved_at(resolve["attribution"]),
        "imagery" => first_retrieved_at(imagery["attribution"]),
        "lidar" => first_retrieved_at(lidar_response["attribution"])
      }.compact,
      "generated_at" => Time.current.iso8601
    }.compact
  end

  # The LiDAR work-unit's acquisition year + survey quality level, when the
  # ingest-lidar stage reported coverage (nil on the no-LiDAR fallback path).
  def lidar_work_unit(lidar_response)
    work_unit = lidar_response.dig("lidar", "work_unit")
    return nil if work_unit.nil?

    {
      "name" => work_unit["name"],
      "year" => work_unit["year"],
      "quality_level" => work_unit["quality_level"]
    }.compact.presence
  end

  # The retrieved_at of a stage's first attribution entry, when present.
  def first_retrieved_at(attribution)
    Array(attribution).filter_map { |a| a["retrieved_at"] }.first
  end

  # --------------------------------------------------------------------------
  # Error labelling
  # --------------------------------------------------------------------------

  # Map a SchemaError message back to the stage that produced it so the failure
  # names the offending stage. The SidecarClient message starts with the entity
  # name ("<Entity> request/response validation failed ..."), which we map to a
  # human stage label.
  def offending_stage(error)
    entity = error.message.split(" ", 2).first
    STAGE_LABELS.fetch(entity, entity)
  end
end
