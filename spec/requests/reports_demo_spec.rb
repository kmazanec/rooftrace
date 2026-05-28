# spec/requests/reports_demo_spec.rb
#
# C5 — Capybara structural test for the /reports/_demo page.
#
# Verifies that the stub page:
#   - Returns 200
#   - Links report.css in the response headers or HTML
#   - Renders the measurements table with "sq ft" values
#   - Renders the RoofTrace wordmark
#   - Renders confidence indicators with data-level attributes
#   - The print route also returns 200

require "rails_helper"

RSpec.describe "GET /reports/_demo", type: :request do
  describe "screen view" do
    before { get "/reports/_demo" }

    it "returns 200" do
      expect(response).to have_http_status(:ok)
    end

    it "includes a link to report.css (possibly fingerprinted by Propshaft)" do
      # Propshaft fingerprints assets: report.css → report-<digest>.css
      expect(response.body).to match(%r{/assets/report[-\w]*\.css})
    end

    it "renders the measurements table" do
      expect(response.body).to include("sq ft")
      expect(response.body).to include("Facet measurements")
    end

    it "renders the RoofTrace wordmark image (Propshaft-fingerprinted path)" do
      # Propshaft: rooftrace-wordmark.svg → rooftrace-wordmark-<digest>.svg
      expect(response.body).to match(/rooftrace-wordmark/i)
    end

    it "renders at least one confidence indicator with a data-level attribute" do
      expect(response.body).to match(/data-level=["'](high|medium|low)["']/)
    end

    it "renders a methodology source label (from LiDAR or from imagery)" do
      expect(response.body).to match(/from LiDAR|from imagery/i)
    end

    it "renders the primary CTA link" do
      expect(response.body).to include("report-cta")
    end

    it "contains the report-table class" do
      expect(response.body).to include("report-table")
    end
  end

  describe "print view" do
    before { get "/reports/_demo/print" }

    it "returns 200" do
      expect(response).to have_http_status(:ok)
    end

    it "renders the measurements table" do
      expect(response.body).to include("sq ft")
    end

    it "renders the orange-on-orange wordmark (PDF header bar variant)" do
      # Propshaft fingerprints: rooftrace-wordmark-onorange.svg → rooftrace-wordmark-onorange-<digest>.svg
      expect(response.body).to match(/rooftrace-wordmark-onorange/i)
    end

    it "contains the print-only signature block" do
      expect(response.body).to include("report-signature-block")
    end

    it "links report.css (possibly fingerprinted by Propshaft)" do
      expect(response.body).to match(%r{/assets/report[-\w]*\.css})
    end
  end

  describe "print query-param variant" do
    before { get "/reports/_demo?print=1" }

    it "returns 200" do
      expect(response).to have_http_status(:ok)
    end
  end
end
