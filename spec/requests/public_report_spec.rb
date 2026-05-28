require "rails_helper"

RSpec.describe "Public share report", type: :request do
  let(:report) { create(:report) }

  it "renders a report by its share token without requiring login" do
    get public_report_path(token: report.share_token)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("RoofTrace report")
  end

  it "sets X-Robots-Tag: noindex (share URLs are bearer credentials)" do
    get public_report_path(token: report.share_token)
    expect(response.headers["X-Robots-Tag"]).to eq("noindex")
  end

  it "links to the token-gated PDF download" do
    get public_report_path(token: report.share_token)
    expect(response.body).to include("/r/#{report.share_token}.pdf")
  end

  it "returns 404 (not a redirect to login) for an unknown token" do
    get public_report_path(token: "Z" * 32)
    expect(response).to have_http_status(:not_found)
    expect(response).not_to redirect_to(login_path)
  end
end
