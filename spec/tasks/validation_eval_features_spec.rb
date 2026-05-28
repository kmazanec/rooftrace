# Exercises the Rails-side feature-detection candidate sweep
# (lib/tasks/validation.rake validation:eval_features) with the detector, the
# Spaces upload, and the URL minter all stubbed, so the slug -> detector ->
# predictions_<slug>.json wiring is verified without live OpenRouter/Spaces
# credentials. A live sweep is manual-only (cost + creds), per ADR-006.
require "rails_helper"
require "rake"
require "aws-sdk-s3"

RSpec.describe "validation:eval_features", type: :task do
  before(:all) do
    Rake.application.rake_require("tasks/validation", [ Rails.root.join("lib").to_s ])
    Rake::Task.define_task(:environment)
  end

  let(:task) { Rake::Task["validation:eval_features"] }
  let(:fd_root) { Rails.root.join("sidecar", "validation", "feature_detection") }

  around do |example|
    existing = Dir.children(fd_root).select { |f| f.start_with?("predictions_") }
    example.run
    (Dir.children(fd_root).select { |f| f.start_with?("predictions_") } - existing).each do |f|
      File.delete(fd_root.join(f))
    end
  end

  after { task.reenable }

  # The Spaces client is built from these env vars (the client itself is stubbed,
  # so these values are never used to make a real connection).
  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("STORAGE_ACCESS_KEY").and_return("test")
    allow(ENV).to receive(:fetch).with("STORAGE_SECRET_KEY").and_return("test")
    allow(ENV).to receive(:fetch).with("STORAGE_ENDPOINT").and_return("https://test.example")
  end

  it "runs each candidate slug through the detector and writes a predictions file per model" do
    detected = [
      { "label" => "chimney", "bbox_norm" => [ 0.1, 0.1, 0.2, 0.2 ], "verified" => true,
        "source" => "imagery", "confidence" => 0.8 }
    ]

    # Stub the detector entirely: assert it is built per candidate slug.
    fake_detector = instance_double(FeatureDetector::OpenRouter)
    built_slugs = []
    allow(FeatureDetector::OpenRouter).to receive(:new) do |model:|
      built_slugs << model
      fake_detector
    end
    allow(fake_detector).to receive(:detect).and_return(detected)

    # Stub the tile upload + URL mint so no Spaces credentials are needed.
    fake_s3 = instance_double(Aws::S3::Client)
    allow(Aws::S3::Client).to receive(:new).and_return(fake_s3)
    allow(fake_s3).to receive(:put_object)
    allow(ImageryUrlMinter).to receive(:call).and_return("https://example.digitaloceanspaces.com/signed")
    # The committed tiles are seed samples with no PNG bytes; skip the read.
    allow(File).to receive(:binread).and_return("\x89PNG".b)

    ENV["CANDIDATE_MODELS"] = "google/gemini-2.5-flash,qwen/qwen2.5-vl-72b-instruct"
    task.invoke

    expect(built_slugs).to contain_exactly("google/gemini-2.5-flash", "qwen/qwen2.5-vl-72b-instruct")

    gemini = JSON.parse(File.read(fd_root.join("predictions_google_gemini-2.5-flash.json")))
    expect(gemini["model"]).to eq("google/gemini-2.5-flash")
    expect(gemini["tiles"]["sample-features-0001"].first["label"]).to eq("chimney")
    expect(File.exist?(fd_root.join("predictions_qwen_qwen2.5-vl-72b-instruct.json"))).to be(true)

    # Tiles are served from the cache/ prefix (allowlist-compatible, no SSRF widen).
    expect(ImageryUrlMinter).to have_received(:call)
      .with(hash_including(object_key: a_string_starting_with("cache/"))).at_least(:once)
  ensure
    ENV.delete("CANDIDATE_MODELS")
  end

  it "records an empty prediction list when a tile detection raises, and continues" do
    fake_detector = instance_double(FeatureDetector::OpenRouter)
    allow(FeatureDetector::OpenRouter).to receive(:new).and_return(fake_detector)
    allow(fake_detector).to receive(:detect).and_raise(StandardError, "VLM 502")

    fake_s3 = instance_double(Aws::S3::Client)
    allow(Aws::S3::Client).to receive(:new).and_return(fake_s3)
    allow(fake_s3).to receive(:put_object)
    allow(ImageryUrlMinter).to receive(:call).and_return("https://example.digitaloceanspaces.com/signed")
    allow(File).to receive(:binread).and_return("\x89PNG".b)

    ENV["CANDIDATE_MODELS"] = "google/gemini-2.5-flash"
    expect { task.invoke }.not_to raise_error

    preds = JSON.parse(File.read(fd_root.join("predictions_google_gemini-2.5-flash.json")))
    expect(preds["tiles"]["sample-features-0001"]).to eq([])
  ensure
    ENV.delete("CANDIDATE_MODELS")
  end
end
