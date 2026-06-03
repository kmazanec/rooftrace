require "rails_helper"

# System-level coverage of the interactive report viewer. Tagged :js because the
# React island (MapLibre + deck.gl) only renders under a real browser. Skipped
# automatically when headless Chrome is unavailable (see spec/support/capybara).
RSpec.describe "Report viewer", type: :system, js: true do
  let(:username) { "demo" }
  let(:password) { "correct-horse" }
  let(:digest)   { BCrypt::Password.create(password) }

  around do |example|
    ENV["DEMO_USERNAME"] = username
    ENV["DEMO_PASSWORD_DIGEST"] = digest
    example.run
  end

  let(:job) { create(:job, address: "123 Main St, Springfield, IL") }
  let!(:measurement) { create(:measurement, :with_geometry, job: job) }

  def log_in!
    visit login_path
    expect(page).to have_field("username")
    fill_in "username", with: username
    fill_in "password", with: password
    click_button "Sign in"
    # Wait for the post-login redirect to the home jobs list before continuing,
    # so a subsequent visit isn't bounced back to /login by the auth gate.
    expect(page).to have_current_path(root_path, wait: 10)
  end

  it "mounts the React island and shows the side-panel numbers without console errors" do
    log_in!
    visit report_job_path(job)

    expect(page).to have_css('[data-controller="viewer"]')

    # The island mounts a child (the map container / deck canvas) into the div.
    expect(page).to have_css('[data-controller="viewer"] *', wait: 10)

    # Side panel renders the fixture numbers + honest-uncertainty source labels.
    expect(page).to have_content("1,684 sq ft")
    expect(page).to have_content("6:12")
    expect(page).to have_content("from LiDAR")

    severe = page.driver.browser.logs.get(:browser).select { |l| l.level == "SEVERE" }
    # MapLibre raster tiles may 401 without a real Mapbox token; ignore network
    # tile errors and assert no JS exceptions from our island.
    app_errors = severe.reject { |l| l.message.include?("api.mapbox.com") || l.message.include?("Failed to load resource") }
    expect(app_errors).to be_empty, "console errors: #{app_errors.map(&:message).join("\n")}"
  end

  it "collapses the side panel below the map on a narrow viewport" do
    log_in!
    page.driver.browser.manage.window.resize_to(600, 900)
    visit report_job_path(job)

    panel_top = page.evaluate_script("document.querySelector('.viewer-panel').getBoundingClientRect().top")
    map_bottom = page.evaluate_script("document.querySelector('.viewer-map').getBoundingClientRect().bottom")
    # Stacked: the panel begins at or below the map's bottom edge.
    expect(panel_top).to be >= map_bottom - 1
  end

  it "places the side panel beside the map on a wide viewport" do
    log_in!
    page.driver.browser.manage.window.resize_to(1280, 900)
    visit report_job_path(job)

    panel_left = page.evaluate_script("document.querySelector('.viewer-panel').getBoundingClientRect().left")
    map_left = page.evaluate_script("document.querySelector('.viewer-map').getBoundingClientRect().left")
    expect(panel_left).to be > map_left
  end
end
