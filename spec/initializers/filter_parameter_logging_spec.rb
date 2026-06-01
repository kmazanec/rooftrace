require "rails_helper"

RSpec.describe "filter parameter logging" do
  it "filters app bearer credentials from parameter logs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

    filtered = filter.filter(
      "token" => "raw-token",
      "app_token" => "raw-app-token",
      "authorization" => "Bearer raw-app-token",
      "HTTP_AUTHORIZATION" => "Bearer raw-app-token",
      "password" => "password"
    )

    expect(filtered).to include(
      "token" => "[FILTERED]",
      "app_token" => "[FILTERED]",
      "authorization" => "[FILTERED]",
      "HTTP_AUTHORIZATION" => "[FILTERED]",
      "password" => "[FILTERED]"
    )
  end
end
