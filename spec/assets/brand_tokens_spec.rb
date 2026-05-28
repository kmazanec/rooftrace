# spec/assets/brand_tokens_spec.rb
#
# C5 — Token-presence test.
#
# Reads brand.css and report.css as plain text and asserts:
#   1. Every documented brand token is DEFINED in brand.css.
#   2. report.css REFERENCES the brand tokens (orange, charcoal, white,
#      the gray scale, and the three confidence tokens).
#   3. CSS files have balanced braces (parse smoke test).
#   4. The orange token hex is the approved construction-cone value.
#
# This spec runs without booting a browser or compiling assets —
# it's a fast, deterministic guard against brand drift.

require "rails_helper"

BRAND_CSS_PATH  = Rails.root.join("app/assets/tailwind/brand.css")
REPORT_CSS_PATH = Rails.root.join("app/assets/stylesheets/report.css")

RSpec.describe "Brand tokens", type: :model do
  let(:brand_css)  { BRAND_CSS_PATH.read }
  let(:report_css) { REPORT_CSS_PATH.read }

  # -----------------------------------------------------------------------
  # Helper: assert balanced braces in a CSS string
  # -----------------------------------------------------------------------
  def braces_balanced?(css)
    opens  = css.count("{")
    closes = css.count("}")
    opens == closes && opens.positive?
  end

  # -----------------------------------------------------------------------
  # Tokens that MUST be defined in brand.css
  # -----------------------------------------------------------------------
  REQUIRED_TOKEN_DEFINITIONS = %w[
    --color-brand-orange
    --color-brand-charcoal
    --color-brand-white
    --color-brand-gray-50
    --color-brand-gray-100
    --color-brand-gray-200
    --color-brand-gray-300
    --color-brand-gray-400
    --color-brand-gray-500
    --color-brand-gray-600
    --color-brand-gray-700
    --color-brand-gray-800
    --color-brand-gray-900
    --color-confidence-high
    --color-confidence-medium
    --color-confidence-low
    --font-sans
    --font-mono
    --text-heading-xl
    --text-heading-lg
    --text-heading-md
    --text-body
    --text-body-sm
    --text-mono-lg
    --text-mono-md
    --text-mono-sm
  ].freeze

  # -----------------------------------------------------------------------
  # Tokens that MUST be referenced (via var(...)) in report.css
  # -----------------------------------------------------------------------
  REQUIRED_REPORT_REFERENCES = %w[
    --color-brand-orange
    --color-brand-charcoal
    --color-brand-white
    --color-brand-gray-50
    --color-brand-gray-100
    --color-brand-gray-200
    --color-brand-gray-300
    --color-brand-gray-400
    --color-brand-gray-500
    --color-brand-gray-600
    --color-brand-gray-700
    --color-brand-gray-800
    --color-confidence-high
    --color-confidence-medium
    --color-confidence-low
    --font-sans
    --font-mono
    --text-body
    --text-body-sm
    --text-heading-xl
    --text-heading-md
    --text-mono-md
  ].freeze

  # -----------------------------------------------------------------------
  # File existence
  # -----------------------------------------------------------------------

  describe "brand.css" do
    it "exists" do
      expect(BRAND_CSS_PATH).to exist
    end

    it "is inside a Tailwind @theme block" do
      expect(brand_css).to include("@theme")
    end

    it "has balanced braces" do
      expect(braces_balanced?(brand_css)).to be(true),
        "brand.css has unbalanced braces (opens=#{brand_css.count("{")}, closes=#{brand_css.count("}")})"
    end
  end

  describe "report.css" do
    it "exists" do
      expect(REPORT_CSS_PATH).to exist
    end

    it "has a @media print block" do
      expect(report_css).to include("@media print")
    end

    it "has balanced braces" do
      expect(braces_balanced?(report_css)).to be(true),
        "report.css has unbalanced braces (opens=#{report_css.count("{")}, closes=#{report_css.count("}")})"
    end
  end

  # -----------------------------------------------------------------------
  # Token definitions in brand.css
  # -----------------------------------------------------------------------

  describe "brand.css token definitions" do
    REQUIRED_TOKEN_DEFINITIONS.each do |token|
      it "defines #{token}" do
        # A definition looks like:  --color-brand-orange: #FF6A1F;
        expect(brand_css).to match(/#{Regexp.escape(token)}\s*:/),
          "Expected brand.css to define #{token}"
      end
    end

    it "uses the approved construction-cone orange (#FF6A1F)" do
      expect(brand_css).to include("--color-brand-orange: #FF6A1F")
    end

    it "defines confidence tokens as grays (no #FF or #EE or #DD hue-dominant hex)" do
      # Extract confidence token lines and assert they do not start with a hue-hot color
      confidence_lines = brand_css.lines.select { |l| l.include?("--color-confidence-") }
      expect(confidence_lines).not_to be_empty
      confidence_lines.each do |line|
        # Warm stoplight colors tend to have high red channel (first two hex digits > 99)
        # and clearly lower green/blue. A gray has R ≈ G ≈ B.
        hex_match = line.match(/#([0-9A-Fa-f]{6})/)
        next unless hex_match

        hex = hex_match[1]
        r = hex[0..1].to_i(16)
        g = hex[2..3].to_i(16)
        b = hex[4..5].to_i(16)

        # Detect stoplight hues:
        #   Red stoplight:    r >> g and r >> b  (e.g. #CC0000)
        #   Yellow stoplight: r >> b and g >> b  (e.g. #FFCC00)
        #   Green stoplight:  g >> r and g >> b  (e.g. #22CC44)
        #
        # Neutral grays (including Tailwind's slightly blue-warm grays like
        # #374151 with chroma ~26) are NOT stoplight colors. We use a dominance
        # threshold of 60 points: a channel must be >60 above another to be
        # considered "clearly dominant / stoplight hue".
        dominance_threshold = 60

        is_red_hue    = (r - g) > dominance_threshold && (r - b) > dominance_threshold
        is_yellow_hue = (r - b) > dominance_threshold && (g - b) > dominance_threshold
        is_green_hue  = (g - r) > dominance_threshold && (g - b) > dominance_threshold

        expect(is_red_hue || is_yellow_hue || is_green_hue).to be(false),
          "Confidence token uses a stoplight-like color ##{hex} on line: #{line.strip}. " \
          "Confidence indicators must be muted grays (no stoplight colors)."
      end
    end
  end

  # -----------------------------------------------------------------------
  # Token references in report.css
  # -----------------------------------------------------------------------

  describe "report.css brand token references" do
    REQUIRED_REPORT_REFERENCES.each do |token|
      it "references #{token} via var()" do
        expect(report_css).to match(/var\(\s*#{Regexp.escape(token)}/),
          "Expected report.css to reference #{token} via var()"
      end
    end

    it "contains .print-only and .screen-only classes" do
      expect(report_css).to include(".print-only")
      expect(report_css).to include(".screen-only")
    end

    it "orange appears only via var(--color-brand-orange) — never as a bare hex outside a var() fallback" do
      # Find every line that references --color-brand-orange in report.css
      orange_lines = report_css.lines.select { |l| l.include?("--color-brand-orange") }
      expect(orange_lines).not_to be_empty,
        "report.css must reference --color-brand-orange at least once"

      # The orange hex is allowed ONLY as the fallback inside
      # var(--color-brand-orange, #FF6A1F). Any other occurrence — even on a line
      # that also contains an unrelated var() — is a bare hard-code and fails.
      # Strip the legitimate fallback occurrences, then look for what remains, so
      # a multi-declaration line like
      #   color: #FF6A1F; background: var(--color-brand-white);
      # is correctly caught.
      fallback = /var\(\s*--color-brand-orange\s*,\s*#FF6A1F\s*\)/i
      bare_orange_lines = report_css.lines.select do |line|
        line.gsub(fallback, "").match?(/#FF6A1F/i)
      end
      expect(bare_orange_lines).to be_empty,
        "report.css hard-codes #FF6A1F outside a var(--color-brand-orange, …) fallback on: #{bare_orange_lines.map(&:strip).join(', ')}"
    end
  end

  # -----------------------------------------------------------------------
  # application.css imports brand.css
  # -----------------------------------------------------------------------

  describe "application.css" do
    let(:application_css_path) { Rails.root.join("app/assets/tailwind/application.css") }
    let(:application_css)      { application_css_path.read }

    it "imports brand.css" do
      expect(application_css).to match(/@import\s+["']\.\/brand\.css["']/)
    end
  end
end
