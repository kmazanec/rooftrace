require "rails_helper"

RSpec.describe "Api::V1 job routes", type: :routing do
  it "routes the literal .json export path to json_exports#show" do
    expect(get: "/api/v1/jobs/11111111-1111-4111-8111-111111111111.json").to route_to(
      controller: "api/v1/json_exports",
      action: "show",
      id: "11111111-1111-4111-8111-111111111111",
      format: :json
    )
  end

  it "routes the extensionless path to jobs#show" do
    expect(get: "/api/v1/jobs/11111111-1111-4111-8111-111111111111").to route_to(
      controller: "api/v1/jobs",
      action: "show",
      id: "11111111-1111-4111-8111-111111111111",
      format: :json
    )
  end
end
