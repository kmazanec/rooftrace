require "rails_helper"

RSpec.describe Report do
  it "assigns a 32-char base32 share token on create" do
    expect(create(:report).share_token).to match(/\A[A-Z2-7]{32}\z/)
  end

  it "gives each report a distinct share token" do
    expect(create(:report).share_token).not_to eq(create(:report).share_token)
  end

  it "uses the share token as its URL param" do
    report = create(:report)
    expect(report.to_param).to eq(report.share_token)
  end
end
