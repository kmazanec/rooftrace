require "rails_helper"

RSpec.describe ArtifactStore do
  let(:client) { instance_double(Aws::S3::Client) }
  let(:bucket) { "rooftrace" }
  subject(:store) { described_class.new(client: client, bucket: bucket) }

  describe "#head" do
    it "returns the last_modified and metadata for an existing object" do
      ts = Time.utc(2026, 5, 28, 12, 0, 0)
      resp = instance_double(Aws::S3::Types::HeadObjectOutput, last_modified: ts, metadata: { "degraded" => "1" })
      allow(client).to receive(:head_object)
        .with(bucket: bucket, key: "artifacts/j/report.pdf").and_return(resp)
      expect(store.head("artifacts/j/report.pdf")).to eq(last_modified: ts, metadata: { "degraded" => "1" })
    end

    it "defaults metadata to an empty hash when the object carries none" do
      ts = Time.utc(2026, 5, 28, 12, 0, 0)
      resp = instance_double(Aws::S3::Types::HeadObjectOutput, last_modified: ts, metadata: nil)
      allow(client).to receive(:head_object).and_return(resp)
      expect(store.head("artifacts/j/report.pdf")).to eq(last_modified: ts, metadata: {})
    end

    it "returns nil when the object does not exist" do
      allow(client).to receive(:head_object)
        .and_raise(Aws::S3::Errors::NotFound.new(nil, "not found"))
      expect(store.head("artifacts/j/report.pdf")).to be_nil
    end

    it "returns nil (treats as a cache miss) on any other S3 error so no raw AWS message leaks" do
      allow(client).to receive(:head_object)
        .and_raise(Aws::S3::Errors::ServiceError.new(nil, "spaces down"))
      expect(store.head("artifacts/j/report.pdf")).to be_nil
    end

    it "rejects a key outside the artifacts/ prefix" do
      expect { store.head("cache/x.png") }.to raise_error(described_class::Error, /artifacts\//)
    end
  end

  describe "#put" do
    it "puts an object under the artifacts/ prefix and returns true" do
      expect(client).to receive(:put_object)
        .with(bucket: bucket, key: "artifacts/j/report.pdf", body: "x", content_type: "application/pdf", metadata: {})
      expect(store.put(key: "artifacts/j/report.pdf", body: "x", content_type: "application/pdf")).to be(true)
    end

    it "passes through user metadata (e.g. the degraded-render flag)" do
      expect(client).to receive(:put_object)
        .with(bucket: bucket, key: "artifacts/j/report.pdf", body: "x", content_type: "application/pdf", metadata: { "degraded" => "1" })
      expect(store.put(key: "artifacts/j/report.pdf", body: "x", content_type: "application/pdf", metadata: { "degraded" => "1" })).to be(true)
    end

    it "rejects a key outside the artifacts/ prefix" do
      expect { store.put(key: "uploads/x", body: "x", content_type: "image/png") }
        .to raise_error(described_class::Error, /artifacts\//)
    end

    it "rejects a blank key" do
      expect { store.put(key: "", body: "x", content_type: "image/png") }
        .to raise_error(described_class::Error, /blank/)
    end
  end
end
