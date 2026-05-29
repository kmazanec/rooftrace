require "rails_helper"

# End-to-end ingest -> FusionJob round-trip (ADR-007). The HTTP ingest is real
# (multipart bundle -> CaptureSession/Capture rows + Spaces uploads to a tmp
# local root); only the sidecar HTTP call is stubbed, returning the committed
# FuseCaptureResponse fixtures. Asserts the additive-measurement contract:
# convergence adds a 2nd row (fused, newest wins) without mutating the original;
# non-convergence leaves the single original row and records a warning.
RSpec.describe "iOS capture fusion integration", type: :request do
  let(:job) { create(:job, status: "ready") }
  let(:fixture_dir) { Rails.root.join("spec/fixtures/ios_sessions/synthetic_house") }
  let(:pipeline_fixtures) { Rails.root.join("spec/fixtures/pipeline") }

  # A canonical LiDAR-only measurement already exists (the base pipeline output).
  let!(:prior) do
    create(:measurement, job: job, source: "lidar", confidence: 0.8,
                         lidar: { "status" => "LIDAR_AVAILABLE",
                                  "point_array_ref" => "cache/#{job.id}/points.npy",
                                  "point_count" => 48_213 },
                         generated_at: 2.minutes.ago)
  end

  around do |example|
    Dir.mktmpdir do |tmp|
      prev = ENV["STORAGE_LOCAL_ROOT"]
      ENV["STORAGE_LOCAL_ROOT"] = tmp
      begin
        example.run
      ensure
        ENV["STORAGE_LOCAL_ROOT"] = prev
      end
    end
  end

  def fixture_payload(name)
    JSON.parse(File.read(pipeline_fixtures.join(name)))["payload"]
  end

  def upload(filename, type)
    Rack::Test::UploadedFile.new(fixture_dir.join(filename), type)
  end

  def ingest_bundle
    base = JSON.parse(File.read(fixture_dir.join("session.json")))
    base["job_id"] = job.id
    params = { session: base.to_json, world_mesh: upload("arkit_mesh.obj", "model/obj") }
    Array(base["captures"]).each do |c|
      idx = c["capture_index"]
      params["photo_#{format('%02d', idx)}".to_sym] = upload("photo_#{format('%02d', idx)}.jpg", "image/jpeg")
      params["depth_#{format('%02d', idx)}".to_sym] = upload("depth_#{format('%02d', idx)}.png", "image/png")
    end
    post api_v1_capture_session_path(job_id: job.id), params: params,
         headers: { "Authorization" => "Bearer #{job.capture_token}" }
  end

  it "ingests the bundle and persists CaptureSession + 8 Captures" do
    expect { ingest_bundle }
      .to change(CaptureSession, :count).by(1).and change(Capture, :count).by(8)
    expect(response).to have_http_status(:ok)
  end

  it "on ICP convergence adds a fused Measurement (newest wins), original intact" do
    ingest_bundle
    capture_session = CaptureSession.last

    # Stub the sidecar to return the converged fixture response, retargeted at
    # this job so the embedded measurement's job_id matches.
    payload = fixture_payload("fuse_capture_response.valid.json")
    payload["job_id"] = job.id
    payload["measurement"]["job_id"] = job.id
    allow(SidecarClient).to receive(:fuse_capture).and_return(payload)

    expect {
      perform_enqueued_jobs { FusionJob.perform_now(job.id, capture_session.id) }
    }.to change { job.measurements.count }.from(1).to(2)

    job.reload
    expect(job.latest_measurement.source).to eq("lidar+device+imagery")
    expect(job.latest_measurement.confidence.to_f).to be >= prior.confidence.to_f
    expect(job.status).to eq("ready")

    # Original LiDAR-only measurement is untouched.
    expect(prior.reload.source).to eq("lidar")
  end

  it "on ICP non-convergence keeps one row and records an icp_alignment_failed warning" do
    ingest_bundle
    capture_session = CaptureSession.last

    payload = fixture_payload("fuse_capture_response.no_measurement.valid.json")
    payload["job_id"] = job.id
    allow(SidecarClient).to receive(:fuse_capture).and_return(payload)

    expect {
      FusionJob.perform_now(job.id, capture_session.id)
    }.not_to change { job.measurements.count }

    expect(prior.reload.warnings.join).to include("icp_alignment_failed")
    expect(job.reload.status).to eq("ready")
  end
end
