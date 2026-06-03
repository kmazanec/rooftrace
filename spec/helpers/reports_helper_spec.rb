require "rails_helper"

# Focus: the PDF-render inlining helpers. Grover renders the report HTML with no
# base URL, so assets referenced by /assets path (img src, <link> css) can't be
# fetched — these helpers inline them instead. Regression coverage for the PDF
# rendering unstyled / with a broken wordmark / mojibaked UTF-8.
RSpec.describe ReportsHelper, type: :helper do
  describe "#inline_brand_svg" do
    it "inlines the SVG markup (not an <img>) so Grover needs no base URL" do
      out = helper.inline_brand_svg("rooftrace-wordmark-onorange.svg", aria_label: "RoofTrace")
      expect(out).to include("<svg")
      expect(out).not_to include("<img")
      expect(out).to be_html_safe
    end

    it "adds a css_class to the root <svg> without duplicating existing attrs" do
      out = helper.inline_brand_svg(
        "rooftrace-wordmark-onorange.svg", aria_label: "RoofTrace", css_class: "report-header-wordmark"
      )
      expect(out).to include('class="report-header-wordmark"')
      # The source SVG already declares role/aria-label exactly once — no dupes.
      expect(out.scan(/role=/).size).to eq(1)
      expect(out.scan(/aria-label=/).size).to eq(1)
    end

    it "returns empty (not an error) when the asset is missing" do
      expect(helper.inline_brand_svg("does-not-exist.svg", aria_label: "x")).to eq("")
    end
  end

  describe "#report_limitations_context" do
    it "flags area_estimated when warnings include area_estimated_no_pitch" do
      m = build(:measurement, source: "imagery", warnings: %w[no_lidar_fallback area_estimated_no_pitch])
      expect(helper.report_limitations_context(m).area_estimated).to be(true)
    end

    it "does not flag area_estimated when warnings are empty" do
      m = build(:measurement, source: "fusion", warnings: [])
      expect(helper.report_limitations_context(m).area_estimated).to be(false)
    end
  end

  describe "#inline_stylesheet" do
    it "inlines the stylesheet as a <style> block (not a <link>)" do
      out = helper.inline_stylesheet("report")
      expect(out).to include("<style")
      expect(out).to include(".report-table")  # a real rule from report.css
      expect(out).not_to include("<link")
    end

    it "returns empty when the stylesheet is missing" do
      expect(helper.inline_stylesheet("nope")).to eq("")
    end
  end
end
