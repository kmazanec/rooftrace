require "net/http"
require "uri"
require "json"

# Talks to the Python FastAPI sidecar over the internal Docker network.
# Exposes `skeleton` and `run_validate` (the pipeline-contract no-op round-trip),
# plus per-stage methods (resolve_address, render_imagery, ingest_lidar,
# refine_outline, fit_planes, fallback_measurement, render_images) that validate
# request and response shapes against PipelineSchema before/after each HTTP call.
#
# Auth: every request includes `Authorization: Bearer <SIDECAR_SHARED_SECRET>`
# per ADR-008. The sidecar rejects with 401 otherwise.
class SidecarClient
  class Error < StandardError; end
  class AuthError < Error; end
  class TimeoutError < Error; end

  # Raised when a request payload violates the schema contract (before the
  # HTTP call is made) or when the sidecar returns a response that violates
  # the contract. The message always names the offending entity so the
  # orchestrator can surface the stage that drifted.
  class SchemaError < Error; end

  DEFAULT_TIMEOUT_SECONDS = 5

  # ---------------------------------------------------------------------------
  # Class-level shortcuts (mirror instance API)
  # ---------------------------------------------------------------------------

  def self.skeleton(job_id:, sent_at:)
    new.skeleton(job_id: job_id, sent_at: sent_at)
  end

  def self.run_validate(request_payload)
    new.run_validate(request_payload)
  end

  def self.resolve_address(address:, timeout: nil)
    new.resolve_address(address: address, timeout: timeout)
  end

  def self.render_imagery(building_polygon:, size_px:, target_gsd_m: nil, timeout: nil)
    new.render_imagery(building_polygon: building_polygon, size_px: size_px,
                       target_gsd_m: target_gsd_m, timeout: timeout)
  end

  def self.ingest_lidar(building_polygon:, parcel_polygon: nil, timeout: nil)
    new.ingest_lidar(building_polygon: building_polygon,
                     parcel_polygon: parcel_polygon, timeout: timeout)
  end

  def self.refine_outline(image_tile_ref:, prior_polygon:, image_geo_bounds:, timeout: nil)
    new.refine_outline(image_tile_ref: image_tile_ref, prior_polygon: prior_polygon,
                       image_geo_bounds: image_geo_bounds, timeout: timeout)
  end

  def self.fit_planes(point_array_ref:, utm_zone:, refined_polygon:, timeout: nil)
    new.fit_planes(point_array_ref: point_array_ref, utm_zone: utm_zone,
                   refined_polygon: refined_polygon, timeout: timeout)
  end

  def self.fallback_measurement(refined_polygon:, inferred_pitch_degrees:, utm_zone:, timeout: nil)
    new.fallback_measurement(refined_polygon: refined_polygon,
                             inferred_pitch_degrees: inferred_pitch_degrees,
                             utm_zone: utm_zone, timeout: timeout)
  end

  def self.render_images(job_id:, bbox:, width_px:, height_px:, timeout: nil)
    new.render_images(job_id: job_id, bbox: bbox, width_px: width_px,
                      height_px: height_px, timeout: timeout)
  end

  def self.fuse_capture(job_id:, capture_mesh_ref:, lidar: nil, timeout: nil)
    new.fuse_capture(job_id: job_id, capture_mesh_ref: capture_mesh_ref,
                     lidar: lidar, timeout: timeout)
  end

  def self.render_evidence_thumbnails(job_id:, photos:, timeout: nil)
    new.render_evidence_thumbnails(job_id: job_id, photos: photos, timeout: timeout)
  end

  def self.project_photo(job_id:, photo_ref:, camera_pose:, facets:, world_mesh_ref: nil,
                         features: nil, arkit_to_utm: nil, utm_epsg: nil,
                         pose_confidence: nil, timeout: nil)
    new.project_photo(job_id: job_id, photo_ref: photo_ref, camera_pose: camera_pose,
                      facets: facets, world_mesh_ref: world_mesh_ref, features: features,
                      arkit_to_utm: arkit_to_utm, utm_epsg: utm_epsg,
                      pose_confidence: pose_confidence, timeout: timeout)
  end

  # ---------------------------------------------------------------------------
  # Constructor
  # ---------------------------------------------------------------------------

  def initialize(base_url: nil, shared_secret: nil, timeout: DEFAULT_TIMEOUT_SECONDS)
    @base_url = base_url || ENV["SIDECAR_URL"] || "http://localhost:8001"
    @shared_secret = shared_secret || ENV["SIDECAR_SHARED_SECRET"]
    @timeout = timeout
    raise ArgumentError, "SIDECAR_SHARED_SECRET is unset; refusing to call sidecar without auth" if @shared_secret.to_s.empty?
  end

  # ---------------------------------------------------------------------------
  # Skeleton + contract-validation methods
  # ---------------------------------------------------------------------------

  def skeleton(job_id:, sent_at:)
    post_json("/skeleton", { job_id: job_id, sent_at: sent_at.iso8601 })
  end

  # POSTs a PipelineRequest to the sidecar's no-op contract-validation endpoint
  # and returns the parsed PipelineResponse hash. The sidecar 422s a malformed
  # request and 409s a schema major mismatch (both surface as SidecarClient::Error).
  def run_validate(request_payload)
    post_json("/pipeline/run-validate", request_payload)
  end

  # ---------------------------------------------------------------------------
  # Per-stage pipeline methods
  # ---------------------------------------------------------------------------

  # POST /pipeline/resolve-address → ResolveAddressResponse
  def resolve_address(address:, timeout: nil)
    payload = {
      "pipelineSchemaVersion" => PipelineSchema.version,
      "address" => address
    }
    validate_request!("ResolveAddressRequest", payload)
    response = post_json("/pipeline/resolve-address", payload, timeout: timeout)
    validate_response!("ResolveAddressResponse", response)
    response
  end

  # POST /pipeline/render-imagery → RenderImageryResponse
  # `target_gsd_m` is optional per the schema; omit the key entirely when nil.
  def render_imagery(building_polygon:, size_px:, target_gsd_m: nil, timeout: nil)
    payload = {
      "pipelineSchemaVersion" => PipelineSchema.version,
      "building_polygon" => building_polygon,
      "size_px" => size_px
    }
    payload["target_gsd_m"] = target_gsd_m unless target_gsd_m.nil?
    validate_request!("RenderImageryRequest", payload)
    response = post_json("/pipeline/render-imagery", payload, timeout: timeout)
    validate_response!("RenderImageryResponse", response)
    response
  end

  # POST /pipeline/ingest-lidar → IngestLidarResponse
  # `parcel_polygon` is optional; omit the key entirely when nil.
  def ingest_lidar(building_polygon:, parcel_polygon: nil, timeout: nil)
    payload = {
      "pipelineSchemaVersion" => PipelineSchema.version,
      "building_polygon" => building_polygon
    }
    payload["parcel_polygon"] = parcel_polygon unless parcel_polygon.nil?
    validate_request!("IngestLidarRequest", payload)
    response = post_json("/pipeline/ingest-lidar", payload, timeout: timeout)
    validate_response!("IngestLidarResponse", response)
    response
  end

  # POST /pipeline/refine-outline → RefineOutlineResponse
  def refine_outline(image_tile_ref:, prior_polygon:, image_geo_bounds:, timeout: nil)
    payload = {
      "pipelineSchemaVersion" => PipelineSchema.version,
      "image_tile_ref" => image_tile_ref,
      "prior_polygon" => prior_polygon,
      "image_geo_bounds" => image_geo_bounds
    }
    validate_request!("RefineOutlineRequest", payload)
    response = post_json("/pipeline/refine-outline", payload, timeout: timeout)
    validate_response!("RefineOutlineResponse", response)
    response
  end

  # POST /pipeline/fit-planes → MeasurementGeometry
  def fit_planes(point_array_ref:, utm_zone:, refined_polygon:, timeout: nil)
    payload = {
      "pipelineSchemaVersion" => PipelineSchema.version,
      "point_array_ref" => point_array_ref,
      "utm_zone" => utm_zone,
      "refined_polygon" => refined_polygon
    }
    validate_request!("FitPlanesRequest", payload)
    response = post_json("/pipeline/fit-planes", payload, timeout: timeout)
    validate_response!("MeasurementGeometry", response)
    response
  end

  # POST /pipeline/fallback-measurement → MeasurementGeometry
  def fallback_measurement(refined_polygon:, inferred_pitch_degrees:, utm_zone:, timeout: nil)
    payload = {
      "pipelineSchemaVersion" => PipelineSchema.version,
      "refined_polygon" => refined_polygon,
      "inferred_pitch_degrees" => inferred_pitch_degrees,
      "utm_zone" => utm_zone
    }
    validate_request!("FallbackMeasurementRequest", payload)
    response = post_json("/pipeline/fallback-measurement", payload, timeout: timeout)
    validate_response!("MeasurementGeometry", response)
    response
  end

  # POST /pipeline/render-images → RenderImageResponse.
  # Renders a deterministic top-down map PNG for the PDF (see ADR-014
  # §Amendment 2026-05-28: a SINGLE map image_ref under the Spaces `artifacts/`
  # prefix — oblique/3D views are deferred). DISTINCT from render_imagery (the satellite tile the
  # geometry pipeline consumes): this serves the report surfaces. A generous
  # timeout is the default because the sidecar's renderer (a headless browser
  # page) has a cold-start cost that can breach the 5s per-call default.
  DEFAULT_RENDER_IMAGES_TIMEOUT_SECONDS = 30

  def render_images(job_id:, bbox:, width_px:, height_px:, timeout: nil)
    payload = {
      "pipelineSchemaVersion" => PipelineSchema.version,
      "job_id" => job_id,
      "bbox" => bbox,
      "width_px" => width_px,
      "height_px" => height_px
    }
    validate_request!("RenderImageRequest", payload)
    response = post_json("/pipeline/render-images", payload,
                         timeout: timeout || DEFAULT_RENDER_IMAGES_TIMEOUT_SECONDS)
    validate_response!("RenderImageResponse", response)
    response
  end

  # POST /pipeline/fuse-capture → FuseCaptureResponse.
  # ICP-aligns an uploaded iOS ARKit capture mesh to the cached public-LiDAR
  # cloud and re-runs the plane fit (ADR-007 capture-bundle fusion; ADR-008
  # Rails↔sidecar boundary). `capture_mesh_ref` is the Spaces `uploads/` key of
  # the ARKit world-mesh OBJ; `lidar` is the optional prior LiDARResult from the
  # original measurement, passed through so the sidecar can reuse its UTM EPSG
  # and point-array. The response carries the fused Measurement on convergence
  # (absent on ICP failure) plus `icp_rmse_m`. A generous default timeout covers
  # the ICP + plane-fit compute, which far exceeds the per-call default.
  FUSE_CAPTURE_TIMEOUT_SECONDS = 120

  def fuse_capture(job_id:, capture_mesh_ref:, lidar: nil, timeout: nil)
    payload = {
      "pipelineSchemaVersion" => PipelineSchema.version,
      "job_id" => job_id,
      "capture_mesh_ref" => capture_mesh_ref
    }
    payload["lidar"] = lidar unless lidar.nil?
    validate_request!("FuseCaptureRequest", payload)
    response = post_json("/pipeline/fuse-capture", payload,
                         timeout: timeout || FUSE_CAPTURE_TIMEOUT_SECONDS)
    validate_response!("FuseCaptureResponse", response)
    response
  end

  # POST /pipeline/render-evidence-thumbnails → RenderEvidenceThumbnailsResponse.
  # Renders normalized thumbnails of a job's capture photos for the report's
  # on-site-evidence section (stored under the Spaces `artifacts/<job_id>/evidence/`
  # prefix). `photos` is an array of { "photo_ref" => String, "sequence_index" =>
  # Integer, "caption" => String|nil }. Like render_images, the renderer has a
  # cold-start cost, so the default timeout is generous. The caller degrades on
  # SidecarClient::Error (omits the evidence block) rather than 5xx-ing the report.
  EVIDENCE_THUMBNAILS_TIMEOUT_SECONDS = 30

  def render_evidence_thumbnails(job_id:, photos:, timeout: nil)
    payload = {
      "pipelineSchemaVersion" => PipelineSchema.version,
      "job_id" => job_id,
      "photos" => photos
    }
    validate_request!("RenderEvidenceThumbnailsRequest", payload)
    response = post_json("/pipeline/render-evidence-thumbnails", payload,
                         timeout: timeout || EVIDENCE_THUMBNAILS_TIMEOUT_SECONDS)
    validate_response!("RenderEvidenceThumbnailsResponse", response)
    response
  end

  # POST /pipeline/project-photo → ProjectPhotoResponse.
  # Projects the measured facets (and detected features) onto one captured photo
  # via pinhole projection with z-buffer occlusion, producing the on-site overlay
  # (composite + SVG under the Spaces `artifacts/<job_id>/projected/` prefix). The
  # solved fusion transform (`arkit_to_utm` + `utm_epsg`) is carried forward from
  # the capture-fusion stage when present; otherwise the sidecar recomputes it from
  # `world_mesh_ref`. The projection compute can exceed the per-call default, so the
  # default timeout is generous. Optional kwargs are omitted from the payload when
  # nil so the schema's optional fields stay absent rather than explicitly null.
  PROJECT_PHOTO_TIMEOUT_SECONDS = 120

  def project_photo(job_id:, photo_ref:, camera_pose:, facets:, world_mesh_ref: nil,
                    features: nil, arkit_to_utm: nil, utm_epsg: nil,
                    pose_confidence: nil, timeout: nil)
    payload = {
      "pipelineSchemaVersion" => PipelineSchema.version,
      "job_id" => job_id,
      "photo_ref" => photo_ref,
      "camera_pose" => camera_pose,
      "facets" => facets
    }
    payload["world_mesh_ref"] = world_mesh_ref unless world_mesh_ref.nil?
    payload["features"] = features unless features.nil?
    payload["arkit_to_utm"] = arkit_to_utm unless arkit_to_utm.nil?
    payload["utm_epsg"] = utm_epsg unless utm_epsg.nil?
    payload["pose_confidence"] = pose_confidence unless pose_confidence.nil?
    validate_request!("ProjectPhotoRequest", payload)
    response = post_json("/pipeline/project-photo", payload,
                         timeout: timeout || PROJECT_PHOTO_TIMEOUT_SECONDS)
    validate_response!("ProjectPhotoResponse", response)
    response
  end

  private

  # ---------------------------------------------------------------------------
  # Schema guards
  # ---------------------------------------------------------------------------

  def validate_request!(entity, payload)
    errors = PipelineSchema.errors_for(entity, payload)
    return if errors.empty?

    raise SchemaError,
          "#{entity} request validation failed: #{errors.join('; ')}"
  end

  def validate_response!(entity, payload)
    errors = PipelineSchema.errors_for(entity, payload)
    return if errors.empty?

    raise SchemaError,
          "#{entity} response validation failed (contract drift?): #{errors.join('; ')}"
  end

  # ---------------------------------------------------------------------------
  # HTTP transport
  # ---------------------------------------------------------------------------

  # `timeout` overrides the instance-level @timeout for this one call. When nil,
  # the instance default (DEFAULT_TIMEOUT_SECONDS for skeleton/run_validate;
  # whatever was passed to initialize for longer-lived clients) is used.
  def post_json(path, payload, timeout: nil)
    effective_timeout = timeout || @timeout
    uri = URI.join(@base_url, path)

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "Bearer #{@shared_secret}"
    request.body = JSON.generate(payload)

    # Use the block form so BOTH open_timeout and read_timeout are honored
    # (open_timeout is silently ignored on the implicit single-shot
    # Net::HTTP.new#request path) and the socket is closed deterministically.
    response = Net::HTTP.start(uri.host, uri.port,
                               use_ssl: uri.scheme == "https",
                               open_timeout: effective_timeout,
                               read_timeout: effective_timeout) do |http|
      http.request(request)
    end
    handle(response)
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    raise TimeoutError, "Sidecar #{path} timed out after #{effective_timeout}s: #{e.message}"
  rescue SystemCallError => e
    # Connection refused / reset / host unreachable, etc.
    raise Error, "Sidecar #{path} connection failed: #{e.class}"
  end

  def handle(response)
    case response.code.to_i
    when 200..299
      parse_body(response.body)
    when 401
      raise AuthError, "Sidecar rejected the bearer token (401)"
    else
      raise Error, "Sidecar returned #{response.code}"
    end
  end

  def parse_body(body)
    JSON.parse(body.to_s)
  rescue JSON::ParserError
    raise Error, "Sidecar returned a non-JSON body"
  end
end
