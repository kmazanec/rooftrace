require "rails_helper"

RSpec.describe "Api::V1 sessions", type: :request do
  let(:username) { "demo" }
  let(:password) { "correct-horse" }

  around do |example|
    ENV["DEMO_USERNAME"] = username
    ENV["DEMO_PASSWORD_DIGEST"] = BCrypt::Password.create(password)
    example.run
  end

  describe "POST /api/v1/sessions" do
    it "returns a new app bearer token for the demo credential" do
      expect {
        post "/api/v1/sessions", params: { username: username, password: password }, as: :json
      }.to change(AppToken, :count).by(1)

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body["app_token"]).to eq(AppToken.last.token)
      expect(Time.iso8601(body["expires_at"])).to be_within(1.second).of(AppToken.last.expires_at)
    end

    it "returns 401 without leaking a token for bad credentials" do
      expect {
        post "/api/v1/sessions", params: { username: username, password: "wrong" }, as: :json
      }.not_to change(AppToken, :count)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).not_to have_key("app_token")
    end
  end
end
