# ReportsDemoController — brand/stylesheet stub for F-04.
#
# Provides a demo view of the report stylesheet and brand tokens so that
# F-12 (web viewer) and F-13 (PDF) have a styled scaffold to build on.
#
# Routes:
#   GET /reports/_demo        → #show  (screen layout)
#   GET /reports/_demo/print  → #print (print layout; same partial, no nav chrome)
#
# Auth note (F-03): F-03 adds require_demo_login to ApplicationController.
# That feature is built in a parallel worktree and is not present here;
# auth will be applied when the branches merge.
class ReportsDemoController < ApplicationController
  # Sample facet data. Real data comes from the measurement pipeline (F-06+).
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
    @address     = SAMPLE_ADDRESS
    @facets      = SAMPLE_FACETS
    @total_sqft  = SAMPLE_TOTAL_SQFT
    @print_mode  = params[:print].present?
    render layout: @print_mode ? "report_print" : "application"
  end

  def print
    @address    = SAMPLE_ADDRESS
    @facets     = SAMPLE_FACETS
    @total_sqft = SAMPLE_TOTAL_SQFT
    @print_mode = true
    render "show", layout: "report_print"
  end
end
