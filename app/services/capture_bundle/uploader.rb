module CaptureBundle
  # Puts every blob of an iOS capture bundle into the `uploads/<job.id>/`
  # partition of Spaces (ADR-010), in the strict order the ingest contract
  # requires: session.json, world mesh, then per-capture photo/depth blobs.
  #
  # This ordering is load-bearing: the controller uploads the WHOLE bundle
  # BEFORE persisting any row or enqueuing FusionJob, so the sidecar can always
  # resolve every ref (world_mesh_ref, photo_ref, depth_ref) by the time fusion
  # runs — no upload/enqueue race.
  #
  # Owns ONLY the blob writes; manifest validation, the size cap, auth, and
  # persistence/idempotency live elsewhere (the controller and
  # CaptureSessionIngester respectively).
  class Uploader
    # @param job [Job] the authenticated, URL-scoped job (supplies the key prefix)
    # @param manifest [Hash] the already-parsed, already-validated session manifest
    # @param params [ActionController::Parameters, Hash] the request params carrying
    #   the multipart blob IOs (world_mesh, photo_NN, depth_NN)
    def initialize(job, manifest, params)
      @job = job
      @manifest = manifest
      @params = params
    end

    # Uploads the full bundle in contract order. Raises SpacesUploader::Error on a
    # storage failure (the controller maps that to a 503). Returns nil — the
    # controller derives the keys it persists from the manifest, not from here.
    def upload_all
      upload_session_json
      upload_world_mesh
      upload_capture_blobs
      nil
    end

    private

    attr_reader :job, :manifest, :params

    # Upload the canonical session.json from the ALREADY-PARSED manifest hash, NOT
    # a second read of the multipart IO. The controller consumed the upload IO via
    # `.read` while parsing; re-reading it here would yield empty bytes for a real
    # device upload (a Tempfile-backed UploadedFile reads once). Re-serializing the
    # parsed hash also normalizes what we persist to what we validated.
    def upload_session_json
      uploader.put(
        key: upload_key("session.json"),
        body: StringIO.new(JSON.generate(manifest)),
        content_type: "application/json"
      )
    end

    def upload_world_mesh
      mesh = params[:world_mesh]
      return if mesh.nil?

      uploader.put(
        key: upload_key(manifest.dig("world_mesh", "filename") || "arkit_mesh.obj"),
        body: mesh.respond_to?(:tempfile) ? mesh.tempfile : mesh,
        content_type: "model/obj"
      )
    end

    def upload_capture_blobs
      Array(manifest["captures"]).each do |capture|
        idx = capture["capture_index"]
        upload_optional_file(capture["photo_filename"], "photo_#{format('%02d', idx)}.jpg", "image/jpeg")
        upload_optional_file(capture["depth_filename"], "depth_#{format('%02d', idx)}.png", "image/png")
      end
    end

    # Uploads params[:<part-name derived from filename>] when present. The iOS
    # client sends each blob under a part named after its manifest filename without
    # extension (e.g. photo_00, depth_00), matching the manifest's
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

    def upload_key(basename)
      "uploads/#{job.id}/#{basename}"
    end

    def uploader
      @uploader ||= SpacesUploader.new
    end
  end
end
