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
    #      Owned by CaptureBundle::Uploader.
    #   5. Persist CaptureSession + Capture rows in one transaction. A duplicate
    #      session_id (an iOS upload retry) is idempotent: 200 with the existing id
    #      WITHOUT re-enqueuing fusion. A session_id already used by a DIFFERENT
    #      job is a collision (409). Owned by CaptureSessionIngester.
    #   6. Enqueue FusionJob only for a newly-created session.
    #
    # This controller keeps the HTTP concerns (auth, the size cap, manifest
    # parsing, the enqueue orchestration, and mapping failures to status codes);
    # blob writes and persistence/idempotency are extracted to the services above.
    class CaptureSessionsController < ApplicationController
      # A capture bundle (8 photos + 8 depth maps + one world mesh + manifest)
      # is bounded; reject anything past this before reading the body so an
      # oversized upload can't exhaust memory/disk. Mirrors the device-side mesh
      # budget (the iOS app caps its OBJ export well under this).
      MAX_BUNDLE_BYTES = 500.megabytes

      skip_before_action :require_demo_login
      # API clients don't carry a CSRF token; they authenticate by bearer.
      skip_forgery_protection

      before_action :authenticate_capture_token!
      # Reject an oversized request up front (413), before parsing the manifest
      # or touching storage, so a too-large upload can't exhaust memory/disk.
      before_action :reject_oversized_request!

      def create
        manifest = parse_manifest
        return if performed? # parse_manifest rendered a 400 on bad JSON / validation

        return if manifest_job_mismatch?(manifest)

        return unless upload_bundle(manifest)

        result = CaptureSessionIngester.new(@job, manifest).persist!
        FusionJob.perform_later(@job.id, result.capture_session.id) if result.newly_created?
        render json: { capture_session_id: result.capture_session.id }, status: :ok
      rescue CaptureSessionIngester::Conflict
        render json: { error: "session_id already used by a different job" }, status: :conflict
      rescue ActiveRecord::RecordInvalid => e
        # A genuine validation failure (NOT the idempotent session_id retry, which
        # the ingester resolves internally). Surface it as a clean 422, never a 500.
        Rails.logger.warn("[capture_sessions] invalid capture bundle: #{e.message}")
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_content
      end

      private

      # Writes the whole bundle to Spaces (contract order) before any DB row. A
      # storage failure mid-upload must not leak a 500 stack to the iOS client:
      # log it and answer 503 so the device retries. Returns true on success,
      # false (having rendered) on failure.
      def upload_bundle(manifest)
        CaptureBundle::Uploader.new(@job, manifest, params).upload_all
        true
      rescue SpacesUploader::Error => e
        Rails.logger.error("[capture_sessions] upload failed: #{e.class}: #{e.message}")
        render json: { error: "storage unavailable, please retry" }, status: :service_unavailable
        false
      end

      def reject_oversized_request!
        # The size cap can only be enforced from a declared Content-Length. A
        # blank/absent header (e.g. a chunked transfer) would make `.to_i` => 0
        # and silently bypass the cap, so require the length up front (411).
        declared = request.content_length
        if declared.blank?
          render json: { error: "Content-Length is required for a capture upload" },
                 status: :length_required
          return
        end

        return if declared.to_i <= MAX_BUNDLE_BYTES

        render json: { error: "capture bundle exceeds the maximum allowed size" },
               status: :content_too_large
      end

      # Returns the parsed manifest Hash, or renders a 400 and returns nil.
      def parse_manifest
        # ADR-007 freezes the manifest part name as "session_json" (the iOS
        # client sends exactly that). Read ONLY that canonical name — there is no
        # legacy client to accommodate.
        raw = params[:session_json]
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
