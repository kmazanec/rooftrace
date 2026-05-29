module Api
  module V1
    # iOS capture upload endpoint (ADR-007 thin-iOS-app, ADR-016 job-scoped
    # bearer). Authenticated by a job-scoped capture_token (24h TTL), NOT the
    # dev-login session.
    #
    # Ingest flow (the strict ordering is load-bearing):
    #   1. Validate the session.json manifest (SessionManifestValidator) — 400 on
    #      a malformed bundle, including an unsupported manifest major version.
    #   2. Confirm the manifest's job_id matches the URL's :job_id — 400 on
    #      mismatch (a bundle for a different job must not land here).
    #   3. Reject an oversized request up front (413).
    #   4. Upload every blob (world-mesh OBJ, photos, depth maps, and the raw
    #      session.json) to Spaces under uploads/<job.id>/ BEFORE persisting any
    #      row and BEFORE enqueuing fusion — so the sidecar can always fetch
    #      every ref by the time FusionJob runs (no upload/enqueue race).
    #   5. Persist CaptureSession + Capture rows in one transaction. A duplicate
    #      session_id (an iOS upload retry) rescues RecordNotUnique and returns
    #      200 with the existing id WITHOUT re-enqueuing fusion (idempotency — the
    #      unique index on capture_sessions.session_id is the guard).
    #   6. Enqueue FusionJob only for a newly-created session.
    class CaptureSessionsController < ApplicationController
      skip_before_action :require_demo_login
      # API clients don't carry a CSRF token; they authenticate by bearer.
      skip_forgery_protection

      before_action :authenticate_capture_token!

      # The guided walk-around bundle (8 JPEGs + 8 depth PNGs + a small mesh) is
      # well under this; a request past it is rejected before any upload work.
      MAX_BUNDLE_BYTES = 500.megabytes

      def create
        manifest = parse_manifest
        return if performed? # parse_manifest rendered a 400 on bad JSON / validation

        return if manifest_job_mismatch?(manifest)
        return if request_too_large?

        upload_session_json
        upload_world_mesh(manifest)
        upload_capture_blobs(manifest)

        persist_and_enqueue(manifest)
      end

      private

      # Returns the parsed manifest Hash, or renders a 400 and returns nil.
      def parse_manifest
        raw = params[:session]
        if raw.blank?
          render_bad_request([ "session manifest part is required" ])
          return nil
        end

        manifest = JSON.parse(raw.respond_to?(:read) ? raw.read : raw)
        validation = SessionManifestValidator.call(manifest)
        unless validation[:valid]
          render_bad_request(validation[:errors])
          return nil
        end
        manifest
      rescue JSON::ParserError
        render_bad_request([ "session manifest is not valid JSON" ])
        nil
      end

      def manifest_job_mismatch?(manifest)
        return false if manifest["job_id"] == params[:job_id]

        render_bad_request([ "manifest job_id does not match the request job_id" ])
        true
      end

      def request_too_large?
        length = request.content_length.to_i
        return false if length <= MAX_BUNDLE_BYTES

        render json: { error: "capture bundle exceeds the maximum allowed size" },
               status: :content_too_large
        true
      end

      # --- Uploads (all under uploads/<job.id>/, BEFORE any DB row) ------------

      def upload_session_json
        json_io = StringIO.new(params[:session].respond_to?(:read) ? params[:session].read : params[:session].to_s)
        uploader.put(
          key: upload_key("session.json"),
          body: json_io,
          content_type: "application/json"
        )
      end

      def upload_world_mesh(manifest)
        mesh = params[:world_mesh]
        return if mesh.nil?

        uploader.put(
          key: upload_key(manifest.dig("world_mesh", "filename") || "arkit_mesh.obj"),
          body: mesh.respond_to?(:tempfile) ? mesh.tempfile : mesh,
          content_type: "model/obj"
        )
      end

      def upload_capture_blobs(manifest)
        Array(manifest["captures"]).each do |capture|
          idx = capture["capture_index"]
          upload_optional_file(capture["photo_filename"], "photo_#{format('%02d', idx)}.jpg", "image/jpeg")
          upload_optional_file(capture["depth_filename"], "depth_#{format('%02d', idx)}.png", "image/png")
        end
      end

      # Uploads params[:<param-name derived from filename>] when present. The iOS
      # client sends each blob under a part named after its manifest filename
      # without extension (e.g. photo_00, depth_00), matching the manifest's
      # photo_filename/depth_filename entries.
      def upload_optional_file(filename, key_basename, content_type)
        return if filename.blank?

        part_name = File.basename(filename, ".*")
        file = params[part_name.to_sym]
        return if file.nil?

        uploader.put(
          key: upload_key(key_basename),
          body: file.respond_to?(:tempfile) ? file.tempfile : file,
          content_type: content_type
        )
      end

      # --- Persistence + enqueue ----------------------------------------------

      def persist_and_enqueue(manifest)
        capture_session = nil
        newly_created = false

        ActiveRecord::Base.transaction do
          capture_session = build_capture_session(manifest)
          capture_session.save!
          build_captures(capture_session, manifest)
          newly_created = true
        end

        FusionJob.perform_later(@job.id, capture_session.id) if newly_created
        render json: { capture_session_id: capture_session.id }, status: :ok
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        # Idempotent retry: the same session_id was already ingested. The DB
        # unique index on capture_sessions.session_id is the real race guard
        # (RecordNotUnique); the model's uniqueness validation usually trips
        # first under a sequential retry (RecordInvalid). Either way, find the
        # existing row and return it WITHOUT re-enqueuing fusion. Any OTHER
        # validation failure is a genuine bad request, not an idempotent retry —
        # re-raise it.
        existing = CaptureSession.find_by(session_id: manifest["session_id"])
        raise e if existing.nil?

        render json: { capture_session_id: existing.id }, status: :ok
      end

      def build_capture_session(manifest)
        @job.capture_sessions.new(
          session_id: manifest["session_id"],
          manifest_version: manifest["manifest_version"],
          started_at: manifest["started_at"],
          ended_at: manifest["ended_at"],
          gps_seed: manifest["gps_origin"],
          device_info: manifest["device_info"],
          world_mesh_ref: upload_key(manifest.dig("world_mesh", "filename") || "arkit_mesh.obj"),
          world_mesh_vertex_count: manifest.dig("world_mesh", "vertex_count"),
          raw_manifest: manifest
        )
      end

      def build_captures(capture_session, manifest)
        Array(manifest["captures"]).each do |capture|
          idx = capture["capture_index"]
          capture_session.captures.create!(
            sequence_index: idx,
            prompt_label: capture["prompt_label"],
            captured_at: capture["timestamp"],
            photo_ref: capture["photo_filename"] ? upload_key("photo_#{format('%02d', idx)}.jpg") : nil,
            depth_ref: capture["depth_filename"] ? upload_key("depth_#{format('%02d', idx)}.png") : nil,
            gps: capture["gps"],
            attitude: capture["attitude"],
            camera_intrinsics: capture.dig("camera_pose", "intrinsics_row_major"),
            camera_extrinsics: capture.dig("camera_pose", "world_to_camera_row_major")
          )
        end
      end

      # --- Helpers -------------------------------------------------------------

      def upload_key(basename)
        "uploads/#{@job.id}/#{basename}"
      end

      def uploader
        @uploader ||= SpacesUploader.new
      end

      def render_bad_request(errors)
        render json: { errors: Array(errors) }, status: :bad_request
      end

      # Assigns @job on success so the action can scope uploads/rows to it.
      def authenticate_capture_token!
        job = Job.authenticate_capture_token(bearer_token)
        if job && job.id == params[:job_id]
          @job = job
          return
        end

        render json: { error: "invalid or expired capture token" }, status: :unauthorized
      end

      def bearer_token
        header = request.authorization.to_s
        return nil unless header.start_with?("Bearer ")

        # `.presence` so a bare "Bearer " (empty token) returns nil, not "" —
        # never let an empty token reach the DB lookup as a blank-string query.
        header.delete_prefix("Bearer ").presence
      end
    end
  end
end
