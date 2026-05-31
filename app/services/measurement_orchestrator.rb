# Chains the geospatial pipeline stages into one persisted Measurement.
#
# The orchestrator owns the Rails-side composition of the per-stage sidecar
# calls (resolve-address -> render-imagery -> ingest-lidar -> refine-outline ->
# fit-planes | fallback-measurement) plus the Rails-resident VLM feature
# detector, and folds their outputs into the unified Measurement contract entity
# before persisting it (ADR-008: Rails owns orchestration/persistence; the
# sidecar owns geometry).
#
# It coordinates three collaborators that own the non-sequencing concerns:
#   * MeasurementIdempotencyCache — the dedupe/cache lookup + input fingerprint.
#   * VlmRunner — the parallel, failure-isolated VLM thread lifecycle + the
#     shared (mutex-guarded) warnings buffer both threads write to.
#   * MeasurementAssembler — the pure transforms that fold stage outputs into the
#     validated Measurement document, confidence, warnings, and provenance.
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
  # the VLM to work with, small enough to stay within one satellite tile.
  IMAGERY_SIZE_PX = 1024

  # Imagery-only confidence ceiling (the assembler owns the math; re-exposed here
  # because callers/specs reference MeasurementOrchestrator::IMAGERY_CONFIDENCE_CAP).
  IMAGERY_CONFIDENCE_CAP = MeasurementAssembler::IMAGERY_CONFIDENCE_CAP

  # Default UTM-zone fallback handling: on the LiDAR-missing path the sidecar
  # never told us a UTM zone (it only returns one with points). We derive an
  # EPSG code from the geocoded longitude/latitude so the fallback measurement
  # can compute planimetric area in a sensible local projection.
  class GeometricFailure < StandardError; end

  def self.call(job)
    new(job).call
  end

  def initialize(job, sidecar: SidecarClient.new, detector_factory: FeatureDetector,
                 url_minter: ImageryUrlMinter, logger: Rails.logger)
    @job = job
    @sidecar = sidecar
    @logger = logger
    @cache = MeasurementIdempotencyCache.new(job, logger: logger)
    @vlm = VlmRunner.new(detector_factory: detector_factory, url_minter: url_minter, logger: logger)
    @assembler = MeasurementAssembler.new
  end

  # Run the chain and return the persisted Measurement (or the cached one).
  # Raises nothing for expected failure modes — it transitions the Job to
  # `failed` via fail_with! and returns nil so GeometryJob need not distinguish.
  def call
    cached = @cache.cached_measurement
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

  # The input fingerprint lives on the idempotency cache; persist writes it onto
  # the new measurement row. Kept here as a thin private accessor (callers/specs
  # reach it via current_fingerprint).
  def current_fingerprint
    @cache.fingerprint
  end

  # Append a warning to the shared (mutex-guarded) buffer the VlmRunner owns —
  # both this thread and the parallel VLM thread write to it.
  def add_warning(message)
    @vlm.add_warning(message)
  end

  # --------------------------------------------------------------------------
  # The chain
  # --------------------------------------------------------------------------

  def run_pipeline
    run_pipeline_stages
  ensure
    # The VLM thread is spawned early (VlmRunner#start) and concurrent with the
    # slow geometric stages. If a later geometric stage raises, the rescues in
    # `call` transition the job to failed but the detector thread would otherwise
    # keep doing external API work against an already-failed job (and repeated
    # failures would accumulate threads). Always clean it up on ANY exit —
    # success OR exception — before propagating. On the happy path VlmRunner#join
    # has already consumed it, so this is a no-op there.
    @vlm.cleanup(job_id: job.id)
  end

  def run_pipeline_stages
    # A cache miss on a previously-terminal Job is an intentional re-run (an
    # address/selection edit invalidated the cached measurement). Reset the
    # status out of terminal here so the stage progression can advance again —
    # advance_to!'s terminal guard only blocks UNintended resurrection (a stray
    # duplicate run), not this explicit re-run.
    job.reset_for_rerun! if job.terminal?

    resolve = resolve_address_stage
    building_polygon = pick_building_polygon(resolve)

    imagery = imagery_stage(building_polygon)
    image_tile_ref = imagery.fetch("image_tile_ref")
    image_geo_bounds = imagery.fetch("image_geo_bounds")

    # Kick off the VLM in parallel with the geometric stages. It detects against
    # the just-rendered tile and the building polygon prior (the refined outline
    # is not yet available; the tile + footprint are enough for bbox detection).
    job.advance_to!(:detecting_features)
    @vlm.start(image_tile_ref: image_tile_ref, roof_polygon: building_polygon)

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

    features = @vlm.join

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
      "lidar" => { "status" => SidecarClient::LIDAR_MISSING },
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
    lidar_response.dig("lidar", "status") == SidecarClient::LIDAR_AVAILABLE
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
  # Assembly + persistence
  # --------------------------------------------------------------------------

  def assemble_and_persist(resolve:, building_polygon:, imagery:, lidar_response:,
                           refined:, refined_polygon:, geometry:, source:, features:)
    warnings = @assembler.collect_warnings(
      accumulated: @vlm.warnings, imagery:, refined:, geometry:
    )
    confidence = @assembler.overall_confidence(
      resolve:, geometry:, lidar_available: source == "fusion"
    )
    measurement_doc = @assembler.build_measurement_document(
      job_id: job.id, footprint: building_polygon, roof_outline: refined_polygon,
      lidar: lidar_response["lidar"], geometry:, features:, source:, confidence:
    )

    @assembler.validate_measurement!(measurement_doc)

    provenance = @assembler.build_provenance(
      resolve:, imagery:, lidar_response:, refined:, geometry:
    )
    persist(
      measurement_doc, provenance:, warnings:,
      total_perimeter_ft: geometry["total_perimeter_ft"],
      geocode: resolve["geocode"],
      parcel_polygon: resolve_parcel(resolve)
    )
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
