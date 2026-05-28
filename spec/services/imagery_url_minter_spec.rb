require "rails_helper"

# ImageryUrlMinter mints a short-lived signed GET URL over a Spaces object key.
# The presigner is stubbed so no AWS credentials/network are needed; the focus
# is the input guards (blank key, and the cache/ prefix defense-in-depth check).
RSpec.describe ImageryUrlMinter, type: :service do
  let(:presigner) { instance_double(Aws::S3::Presigner) }
  let(:client) { instance_double(Aws::S3::Client) }

  subject(:minter) { described_class.new(client: client) }

  before do
    allow(Aws::S3::Presigner).to receive(:new).and_return(presigner)
    allow(presigner).to receive(:presigned_url).and_return("https://example.test/signed")
  end

  it "presigns a key under the cache/ prefix" do
    url = minter.call(object_key: "cache/imagery/abc123.png")

    expect(url).to eq("https://example.test/signed")
    expect(presigner).to have_received(:presigned_url).with(
      :get_object, hash_including(key: "cache/imagery/abc123.png")
    )
  end

  it "raises on a blank key" do
    expect { minter.call(object_key: "  ") }
      .to raise_error(ImageryUrlMinter::Error, /blank/)
  end

  it "refuses to presign a key outside the cache/ prefix (defense-in-depth)" do
    expect { minter.call(object_key: "uploads/secret.png") }
      .to raise_error(ImageryUrlMinter::Error, %r{cache/})
    expect { minter.call(object_key: "backups/db.sql") }
      .to raise_error(ImageryUrlMinter::Error, %r{cache/})

    expect(presigner).not_to have_received(:presigned_url)
  end
end
