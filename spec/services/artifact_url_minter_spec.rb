require "rails_helper"

# ArtifactUrlMinter mints a short-lived signed GET URL over a Spaces object key
# under the artifacts/ prefix (report PDF + map PNG). The presigner is stubbed so
# no AWS credentials/network are needed; the focus is the input guards (blank
# key, and the artifacts/ prefix defense-in-depth check — the mirror of
# ImageryUrlMinter's cache/ lock).
RSpec.describe ArtifactUrlMinter, type: :service do
  let(:presigner) { instance_double(Aws::S3::Presigner) }
  let(:client) { instance_double(Aws::S3::Client) }

  subject(:minter) { described_class.new(client: client) }

  before do
    allow(Aws::S3::Presigner).to receive(:new).and_return(presigner)
    allow(presigner).to receive(:presigned_url).and_return("https://example.test/signed")
  end

  it "presigns a key under the artifacts/ prefix" do
    url = minter.call(object_key: "artifacts/job-1/report.pdf")

    expect(url).to eq("https://example.test/signed")
    expect(presigner).to have_received(:presigned_url).with(
      :get_object, hash_including(key: "artifacts/job-1/report.pdf")
    )
  end

  it "raises on a blank key" do
    expect { minter.call(object_key: "  ") }
      .to raise_error(ArtifactUrlMinter::Error, /blank/)
  end

  it "refuses to presign a key outside the artifacts/ prefix (defense-in-depth)" do
    expect { minter.call(object_key: "cache/imagery/abc.png") }
      .to raise_error(ArtifactUrlMinter::Error, %r{artifacts/})
    expect { minter.call(object_key: "uploads/secret.png") }
      .to raise_error(ArtifactUrlMinter::Error, %r{artifacts/})

    expect(presigner).not_to have_received(:presigned_url)
  end

  it "defaults to a bounded (24h) TTL and honors an override" do
    minter.call(object_key: "artifacts/job-1/report.pdf")
    expect(presigner).to have_received(:presigned_url).with(
      :get_object, hash_including(expires_in: 24.hours.to_i)
    )

    minter.call(object_key: "artifacts/job-1/report.pdf", expires_in: 5.minutes)
    expect(presigner).to have_received(:presigned_url).with(
      :get_object, hash_including(expires_in: 5.minutes.to_i)
    )
  end
end
