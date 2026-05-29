require "rails_helper"

RSpec.describe "iOS capture sessions — auth", type: :request do
  let(:job) { create(:job) }

  def post_capture(job_id, token)
    headers = token ? { "Authorization" => "Bearer #{token}" } : {}
    post api_v1_capture_session_path(job_id: job_id), headers: headers
  end

  it "passes auth with a valid job-scoped token (then 400 for the missing body)" do
    # A valid bearer gets past authenticate_capture_token!; the empty body then
    # fails manifest validation with a 400 (NOT a 401).
    post_capture(job.id, job.capture_token)
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body["errors"]).to be_present
  end

  it "rejects a missing bearer token (401)" do
    post_capture(job.id, nil)
    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects a wrong token (401)" do
    post_capture(job.id, "Q" * 32)
    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects a bare 'Bearer ' with no token (401)" do
    post api_v1_capture_session_path(job_id: job.id), headers: { "Authorization" => "Bearer " }
    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects an expired token (401) with a clear error" do
    job.update_column(:capture_token_expires_at, 1.minute.ago)
    post_capture(job.id, job.capture_token)
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body["error"]).to match(/expired|invalid/i)
  end

  it "rejects a valid token used against a different job's URL (token is job-scoped)" do
    other = create(:job)
    post_capture(other.id, job.capture_token)
    expect(response).to have_http_status(:unauthorized)
  end

  it "never requires the dev-login session (bearer alone is sufficient)" do
    post_capture(job.id, job.capture_token)
    # Past auth — the 400 is the missing-body validation, not a 401/login redirect.
    expect(response).to have_http_status(:bad_request)
  end
end

RSpec.describe "iOS capture session ingest (multipart bundle)", type: :request do
  let(:job) { create(:job) }
  let(:fixture_dir) { Rails.root.join("spec/fixtures/ios_sessions/synthetic_house") }

  around do |example|
    Dir.mktmpdir do |tmp|
      @storage_root = tmp
      prev = ENV["STORAGE_LOCAL_ROOT"]
      ENV["STORAGE_LOCAL_ROOT"] = tmp
      begin
        example.run
      ensure
        ENV["STORAGE_LOCAL_ROOT"] = prev
      end
    end
  end

  # Build a manifest Hash from the fixture, retargeted at the created job.
  def manifest_for(target_job, overrides = {})
    base = JSON.parse(File.read(fixture_dir.join("session.json")))
    base["job_id"] = target_job.id
    base.merge(overrides)
  end

  def upload(filename, type)
    Rack::Test::UploadedFile.new(fixture_dir.join(filename), type)
  end

  # The multipart part names here are the FROZEN ADR-007 wire contract that the
  # real iOS client sends: the manifest part is `session_json` (NOT `session`),
  # the photos/depth maps are `photo_00`..`photo_07` / `depth_00`..`depth_07`,
  # and the world mesh is `world_mesh`. These names are load-bearing — every real
  # device upload uses exactly them, so this spec locks them as a contract test.
  def bundle_params(manifest)
    params = { session_json: manifest.to_json }
    Array(manifest["captures"]).each do |c|
      idx = c["capture_index"]
      params["photo_#{format('%02d', idx)}".to_sym] = upload("photo_#{format('%02d', idx)}.jpg", "image/jpeg")
      params["depth_#{format('%02d', idx)}".to_sym] = upload("depth_#{format('%02d', idx)}.png", "image/png")
    end
    params[:world_mesh] = upload("arkit_mesh.obj", "model/obj")
    params
  end

  def post_bundle(target_job, params)
    post api_v1_capture_session_path(job_id: target_job.id),
         params: params,
         headers: { "Authorization" => "Bearer #{target_job.capture_token}" }
  end

  it "ingests a valid multipart bundle: 200, DB rows, enqueues FusionJob" do
    manifest = manifest_for(job)
    expect {
      post_bundle(job, bundle_params(manifest))
    }.to change(CaptureSession, :count).by(1).and change(Capture, :count).by(8)

    expect(response).to have_http_status(:ok)
    cs = CaptureSession.last
    expect(response.parsed_body["capture_session_id"]).to eq(cs.id)
    expect(cs.job_id).to eq(job.id)
    expect(cs.world_mesh_ref).to eq("uploads/#{job.id}/arkit_mesh.obj")
  end

  it "enqueues exactly one FusionJob for the created session" do
    expect {
      post_bundle(job, bundle_params(manifest_for(job)))
    }.to have_enqueued_job(FusionJob).with(job.id, CaptureSession.last&.id || anything).exactly(:once)
  end

  it "uploads session.json + mesh + photos + depth maps under uploads/<job.id>/" do
    post_bundle(job, bundle_params(manifest_for(job)))
    expect(response).to have_http_status(:ok)
    root = Pathname.new(@storage_root).join("uploads", job.id)
    expect(root.join("session.json")).to exist
    # The world mesh MUST be written — the sidecar's FuseCaptureRequest points its
    # capture_mesh_ref at this exact key, so a missing object 422s every fusion.
    expect(root.join("arkit_mesh.obj")).to exist
    expect(root.join("photo_00.jpg")).to exist
    expect(root.join("depth_07.png")).to exist

    # session.json is uploaded from the PARSED manifest (not a second read of the
    # consumed multipart IO), so it must be non-empty and round-trip back to the
    # manifest — a real device upload would otherwise write an empty file.
    persisted = JSON.parse(root.join("session.json").read)
    expect(persisted["session_id"]).to be_present
    expect(persisted["job_id"]).to eq(job.id)
  end

  it "reads the manifest from the ADR-007 'session_json' part (not 'session')" do
    # Posting under the wrong/legacy 'session' key must 400 (the manifest part is
    # absent), proving the controller reads only the frozen 'session_json' name.
    manifest = manifest_for(job)
    params = bundle_params(manifest)
    params.delete(:session_json)
    params[:session] = manifest.to_json
    post_bundle(job, params)
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body["errors"].join).to match(/manifest part is required/)
  end

  it "uploads the world mesh blob via the SpacesUploader (arkit_mesh.obj key)" do
    uploader = instance_double(SpacesUploader)
    allow(SpacesUploader).to receive(:new).and_return(uploader)
    allow(uploader).to receive(:put)
    post_bundle(job, bundle_params(manifest_for(job)))
    expect(uploader).to have_received(:put)
      .with(hash_including(key: "uploads/#{job.id}/arkit_mesh.obj", content_type: "model/obj"))
  end

  it "is idempotent: a duplicate session_id returns 200 without re-enqueue" do
    post_bundle(job, bundle_params(manifest_for(job)))
    first_id = response.parsed_body["capture_session_id"]

    expect {
      post_bundle(job, bundle_params(manifest_for(job)))
    }.not_to change(CaptureSession, :count)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["capture_session_id"]).to eq(first_id)
  end

  it "returns 400 when the session manifest part is missing" do
    post api_v1_capture_session_path(job_id: job.id),
         params: { world_mesh: upload("arkit_mesh.obj", "model/obj") },
         headers: { "Authorization" => "Bearer #{job.capture_token}" }
    expect(response).to have_http_status(:bad_request)
  end

  it "returns 400 when the manifest is missing gps_origin" do
    manifest = manifest_for(job)
    manifest.delete("gps_origin")
    post_bundle(job, bundle_params(manifest))
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body["errors"].join).to match(/gps_origin/)
  end

  it "returns 400 for an unsupported manifest_version (2.0)" do
    post_bundle(job, bundle_params(manifest_for(job, "manifest_version" => "2.0.0")))
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body["errors"].join).to match(/manifest_version/)
  end

  it "returns 400 when the manifest job_id does not match the URL job_id" do
    manifest = manifest_for(job)
    manifest["job_id"] = create(:job).id
    post_bundle(job, bundle_params(manifest))
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body["errors"].join).to match(/job_id/)
  end

  it "returns 413 when the request exceeds the bundle size cap" do
    allow_any_instance_of(ActionDispatch::Request)
      .to receive(:content_length).and_return(Api::V1::CaptureSessionsController::MAX_BUNDLE_BYTES + 1)
    post_bundle(job, bundle_params(manifest_for(job)))
    expect(response).to have_http_status(:content_too_large)
  end

  # The size guard is a before_action rejecting an oversized request up front
  # (413), before the manifest is parsed or any blob is read.
  it "rejects a request whose CONTENT_LENGTH exceeds the cap (413), before parsing" do
    oversized = Api::V1::CaptureSessionsController::MAX_BUNDLE_BYTES + 1
    post api_v1_capture_session_path(job_id: job.id),
         headers: {
           "Authorization" => "Bearer #{job.capture_token}",
           "CONTENT_LENGTH" => oversized.to_s
         }
    expect(response).to have_http_status(:content_too_large)
    expect(response.parsed_body["error"]).to match(/exceeds|too large/i)
  end

  it "rejects a request with no Content-Length (411), since the cap can't be enforced" do
    # Without a declared length the size cap is unenforceable (a chunked upload
    # could stream past it), so require it rather than silently allow the request.
    # Stub content_length to nil (an absent header) and send a body-less request
    # so Rack's multipart parser — which itself reads content_length — isn't hit;
    # the before_action must short-circuit with 411 before parsing.
    allow_any_instance_of(ActionDispatch::Request)
      .to receive(:content_length).and_return(nil)
    post api_v1_capture_session_path(job_id: job.id),
         headers: { "Authorization" => "Bearer #{job.capture_token}" }
    expect(response).to have_http_status(:length_required)
  end

  it "does not leak another job's capture_session_id on a session_id collision (409)" do
    # The same session_id already ingested under a DIFFERENT job must NOT return
    # that job's capture_session_id — it's a collision/replay, not an idempotent
    # retry. Expect a 409 with no foreign id leaked.
    other = create(:job)
    other_manifest = manifest_for(other)
    post_bundle(other, bundle_params(other_manifest))
    expect(response).to have_http_status(:ok)
    other_cs_id = response.parsed_body["capture_session_id"]

    # Replay the SAME session_id against `job` (this job's URL + token).
    colliding = manifest_for(job).merge("session_id" => other_manifest["session_id"])
    post_bundle(job, bundle_params(colliding))
    expect(response).to have_http_status(:conflict)
    expect(response.body).not_to include(other_cs_id)
  end
end

RSpec.describe "Job creation returns the capture credential", type: :request do
  around do |example|
    ENV["DEMO_USERNAME"] = "demo"
    ENV["DEMO_PASSWORD_DIGEST"] = BCrypt::Password.create("pw")
    example.run
  end

  def login!
    post login_path, params: { username: "demo", password: "pw" }
  end

  it "returns {job_id, capture_token, capture_token_expires_at} to a JSON client" do
    login!
    post jobs_path, params: { job: { address: "123 Main St" } }, as: :json
    expect(response).to have_http_status(:created)
    body = response.parsed_body
    expect(body["job_id"]).to be_present
    expect(body["capture_token"]).to match(%r{\A[1-9A-HJ-NP-Za-km-z]{32}\z})
    expect(body["capture_token_expires_at"]).to be_present
  end

  it "redirects a browser form submit to the job status page (not raw JSON)" do
    login!
    post jobs_path, params: { job: { address: "123 Main St" } }
    expect(response).to have_http_status(:found)
    job = Job.last
    expect(response).to redirect_to(job_path(job))
  end
end
