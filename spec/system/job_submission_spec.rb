# System-level test for the F-11 job submission flow.
#
# Driver choice: rack_test (no headless browser needed).
# The submit → redirect → status page flow is server-side; the live
# ActionCable Turbo Stream updates require a WebSocket — those are covered
# by the broadcast-sequence model spec. Here we assert the rendered HTML
# for all status states.
#
# Session approach: each example logs in via the form within the example.
# Capybara resets the session between examples (Capybara.reset_session!),
# so login must happen inside each example, not in a before block.
# A shared helper is used to keep examples concise.
#
# GeometryJob is stubbed to a no-op so the enqueue path can be tested
# without the real pipeline; status transitions are driven directly via
# update_columns.
#
# JS driver note (Fix 1): no headless Chrome / Selenium / Cuprite was
# available in this environment (chromedriver not found; ferrum/cuprite gems
# not present). The live-update render path is therefore covered by a
# request/integration spec in spec/requests/jobs_spec.rb that:
#   1. Loads the show page (subscribes the stream)
#   2. Calls job.advance_to!(:ready) — the real broadcast path
#   3. Asserts the broadcast's rendered HTML contains the report link
#      (the exact markup the browser Turbo Stream would inject)
# See "turbo stream live-update render path" context in jobs_spec.rb.

require "rails_helper"

RSpec.describe "Job submission flow", type: :system do
  let(:username) { "demo" }
  let(:password) { "correct-horse" }
  let(:digest)   { BCrypt::Password.create(password) }

  def log_in
    visit login_path
    fill_in "Username", with: username
    fill_in "Password", with: password
    click_button "Sign in"
  end

  around do |example|
    ENV["DEMO_USERNAME"] = username
    ENV["DEMO_PASSWORD_DIGEST"] = digest
    example.run
  end

  describe "happy path: submit → status page" do
    it "submits an address and lands on the status page" do
      allow(GeometryJob).to receive(:perform_later)
      log_in
      visit new_job_path
      fill_in "Property address", with: "742 Evergreen Terrace, Springfield, IL 62701"
      click_button "Start measurement"

      # After the redirect, we should be on the status page showing the address
      # and per-stage progress. With rack_test, current_path may show the form's
      # POST action URL rather than the final redirect destination; we assert on
      # page content instead.
      job = Job.last!
      expect(page).to have_content("742 Evergreen Terrace, Springfield, IL 62701")
      expect(page).to have_content("Roof measurement")
    end

    it "shows per-stage progress labels on the status page" do
      allow(GeometryJob).to receive(:perform_later)
      log_in
      visit new_job_path
      fill_in "Property address", with: "1600 Pennsylvania Ave NW, Washington, DC 20500"
      click_button "Start measurement"

      expect(page).to have_content("Looking up address")
    end
  end

  describe "ready state" do
    it "shows the report link when job is ready" do
      log_in
      job = create(:job)
      job.update_columns(status: "ready")

      visit job_path(job)
      expect(page).to have_link(href: /\/jobs\/#{job.id}\/report/)
    end
  end

  describe "failure path" do
    it "shows a plain-language error when the job fails with a message" do
      log_in
      job = create(:job)
      job.update_columns(
        status: "failed",
        last_error: "We could not find a building at this address — please check the spelling and try again."
      )

      visit job_path(job)
      expect(page).to have_content("We could not find a building at this address")
    end

    it "shows a fallback error when the job fails with no message" do
      log_in
      job = create(:job)
      job.update_columns(status: "failed", last_error: nil)

      visit job_path(job)
      expect(page).to have_content("Something went wrong")
    end

    it "shows a back-to-form link when the job fails" do
      log_in
      job = create(:job)
      job.update_columns(status: "failed", last_error: "Address not geocodable.")

      visit job_path(job)
      expect(page).to have_link(href: new_job_path)
    end
  end
end
