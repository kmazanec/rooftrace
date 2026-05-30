# ReportsDemoController — brand/stylesheet demo.
#
# Provides a demo view of the report stylesheet and brand tokens so that
# the web viewer (ADR-013) and the PDF report have a styled scaffold to build on.
#
# Routes:
#   GET /reports/_demo        → #show  (screen layout)
#   GET /reports/_demo/print  → #print (print layout; same partial, no nav chrome)
#
# Auth: this is a public brand/stylesheet reference page with only hardcoded
# sample data — no contractor data, no DB reads. It opts out of the dev-login
# gate (like the public report viewer), so the design scaffold stays viewable
# without a session.
class ReportsDemoController < ApplicationController
  skip_before_action :require_demo_login
  before_action :assign_sample_data

  # Sample facet data. Real data comes from the measurement pipeline.
  SAMPLE_FACETS = [
    {
      name: "Front slope",
      area_sqft: 842,
      pitch: "6/12",
      confidence: "high",
      source: "from LiDAR"
    },
    {
      name: "Rear slope",
      area_sqft: 791,
      pitch: "6/12",
      confidence: "high",
      source: "from LiDAR"
    },
    {
      name: "Left dormer",
      area_sqft: 204,
      pitch: "4/12",
      confidence: "medium",
      source: "from imagery"
    },
    {
      name: "Right dormer",
      area_sqft: 198,
      pitch: "4/12",
      confidence: "medium",
      source: "from imagery"
    },
    {
      name: "Garage shed",
      area_sqft: 132,
      pitch: "2/12",
      confidence: "low",
      source: "from imagery"
    }
  ].freeze

  SAMPLE_ADDRESS = "1234 Elm Street, Lincoln, NE 68501"
  SAMPLE_TOTAL_SQFT = SAMPLE_FACETS.sum { |f| f[:area_sqft] }

  def show
    @print_mode = params[:print].present?
    render layout: @print_mode ? "report_print" : "application"
  end

  def print
    @print_mode = true
    render "show", layout: "report_print"
  end

  private

  def assign_sample_data
    @address    = SAMPLE_ADDRESS
    @facets     = SAMPLE_FACETS
    @total_sqft = SAMPLE_TOTAL_SQFT
  end
end
