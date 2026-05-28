require "rails_helper"

RSpec.describe Report do
  it "assigns an unguessable base58 share token on create (has_secure_token, 32 chars)" do
    expect(create(:report).share_token).to match(%r{\A[1-9A-HJ-NP-Za-km-z]{32}\z})
  end

  it "gives each report a distinct share token" do
    expect(create(:report).share_token).not_to eq(create(:report).share_token)
  end

  it "uses the share token as its URL param" do
    report = create(:report)
    expect(report.to_param).to eq(report.share_token)
  end
end
