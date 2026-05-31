# Persists a validated iOS capture bundle (CaptureSession + its Captures) in one
# transaction, with the idempotency + cross-job-collision guarantees the ingest
# contract requires. Runs AFTER CaptureBundle::Uploader has written every blob, so
# the persisted refs always point at objects that already exist in Spaces.
#
# The unique index on capture_sessions.session_id is the real race guard. A
# duplicate session_id (an iOS upload retry) is idempotent: find the existing row
# for THIS job and return it WITHOUT re-enqueuing fusion. A session_id already
# used by a DIFFERENT job is a collision/replay, not a retry — raise Conflict so
# the controller can 409 without ever leaking the other job's id.
class CaptureSessionIngester
  # Raised when the bundle's session_id already belongs to a different job.
  class Conflict < StandardError; end

  # What the controller needs to decide its response:
  #   capture_session — the persisted (or pre-existing) row, whose id is rendered
  #   newly_created   — true only for a fresh insert, so the controller enqueues
  #                     FusionJob exactly once (a retry must not re-enqueue)
  Result = Struct.new(:capture_session, :newly_created, keyword_init: true) do
    def newly_created?
      newly_created
    end
  end

  def initialize(job, manifest)
    @job = job
    @manifest = manifest
  end

  # @return [Result]
  # @raise [CaptureSessionIngester::Conflict] session_id belongs to another job
  # @raise [ActiveRecord::RecordInvalid] a genuine validation failure (NOT the
  #   idempotent session_id-uniqueness retry) — the controller renders it as 422
  def persist!
    capture_session = nil

    ActiveRecord::Base.transaction do
      capture_session = build_capture_session
      capture_session.save!
      build_captures(capture_session)
    end

    Result.new(capture_session: capture_session, newly_created: true)
  rescue ActiveRecord::RecordNotUnique
    # The DB unique index tripped (a true concurrent retry). Resolve idempotently.
    resolve_duplicate
  rescue ActiveRecord::RecordInvalid => e
    # The model's `uniqueness: true` validation usually trips FIRST under a
    # sequential retry, so the session_id-uniqueness case arrives here as a
    # RecordInvalid — treat it as the same idempotent retry. ANY OTHER validation
    # failure is a genuine bad bundle: re-raise so the controller renders a 422
    # (never swallowed into a false idempotent 200).
    raise e unless session_id_taken?(e)

    resolve_duplicate
  end

  private

  attr_reader :job, :manifest

  # Scope the idempotency lookup to the authenticated job: a session_id is a
  # client-generated UUID that is globally unique by design (the DB index is
  # global), but the idempotency RESPONSE must never leak another job's id.
  #   * row belongs to THIS job  -> genuine retry, return it (not newly created)
  #   * row belongs to ANOTHER job -> collision/replay, raise Conflict (409)
  def resolve_duplicate
    existing = job.capture_sessions.find_by(session_id: manifest["session_id"])
    return Result.new(capture_session: existing, newly_created: false) if existing

    raise Conflict if CaptureSession.exists?(session_id: manifest["session_id"])

    # The unique-constraint signal fired but no row is found under any job — the
    # state is genuinely inconsistent (e.g. a different unique index, or a row
    # destroyed mid-retry). Surface it rather than masking it as a clean response.
    raise ActiveRecord::RecordNotUnique, "session_id constraint tripped but no row found"
  end

  def session_id_taken?(error)
    error.record.errors.of_kind?(:session_id, :taken)
  end

  def build_capture_session
    job.capture_sessions.new(
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

  def build_captures(capture_session)
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

  def upload_key(basename)
    "uploads/#{job.id}/#{basename}"
  end
end
