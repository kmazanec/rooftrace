require "rails_helper"

RSpec.describe "GET /health", type: :request do
  context "when spaces probe is skipped (unit-level)" do
    around do |ex|
      original = ENV.to_h.slice("SKIP_SPACES_CHECK", "GIT_SHA")
      ENV["SKIP_SPACES_CHECK"] = "1"
      ENV["GIT_SHA"] = "deadbeef"
      begin
        ex.run
      ensure
        ENV["SKIP_SPACES_CHECK"] = original["SKIP_SPACES_CHECK"]
        ENV["GIT_SHA"] = original["GIT_SHA"]
      end
    end

    it "reports Rails version, git SHA, time, Postgres+PostGIS ok" do
      get "/health"
      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      expect(body["status"]).to eq("ok")
      expect(body["rails_version"]).to eq(Rails.version)
      expect(body["git_sha"]).to eq("deadbeef")
      expect(body["time"]).to match(/\A\d{4}-\d{2}-\d{2}T/)
      expect(body["postgres"]["ok"]).to eq(true)
      expect(body["postgres"]["postgis_version"]).to match(/USE_GEOS=1/)

      expect(body["spaces"].keys).to match_array(SpacesHealth::BUCKETS)
      expect(body["spaces"].values.uniq).to eq([ "skipped" ])
    end
  end

  context "when Spaces probe fails (missing creds)" do
    it "returns 503 and surfaces the failure per-bucket" do
      original = ENV.to_h.slice(*%w[SKIP_SPACES_CHECK STORAGE_ACCESS_KEY STORAGE_SECRET_KEY STORAGE_ENDPOINT])
      ENV.delete("SKIP_SPACES_CHECK")
      %w[STORAGE_ACCESS_KEY STORAGE_SECRET_KEY STORAGE_ENDPOINT].each { ENV.delete(_1) }

      get "/health"

      expect(response).to have_http_status(:service_unavailable)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("degraded")
      expect(body["spaces"].values).to all(start_with("fail:"))
    ensure
      original&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end
  end
end
