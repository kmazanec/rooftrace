require "rails_helper"

RSpec.describe "reports/_limitations", type: :view do
  it "states pitch is unknown and area estimated on the imagery path" do
    render partial: "reports/limitations",
           locals: { measurement: build(:measurement, source: "imagery", warnings: %w[area_estimated_no_pitch]) }
    expect(rendered).to match(/pitch was not measured/i)
    expect(rendered).to match(/reported as\s+unknown/)
    expect(rendered).not_to include("Pitch values are derived from the point cloud")
    expect(rendered).to include("Field verification")
  end

  it "keeps the point-cloud pitch statement on the LiDAR path" do
    render partial: "reports/limitations",
           locals: { measurement: build(:measurement, source: "lidar") }
    expect(rendered).to include("Pitch values are derived from the point cloud")
    expect(rendered).to include("Field verification")
  end

  it "renders the area-estimate disclosure only when area_estimated_no_pitch is present" do
    render partial: "reports/limitations",
           locals: { measurement: build(:measurement, source: "imagery", warnings: %w[area_estimated_no_pitch]) }
    expect(rendered).to include("planimetric estimate")
  end

  it "omits the area-estimate disclosure on the LiDAR path" do
    render partial: "reports/limitations",
           locals: { measurement: build(:measurement, source: "lidar", warnings: []) }
    expect(rendered).not_to include("planimetric estimate")
  end
end
