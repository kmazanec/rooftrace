# Capybara configuration for system specs.
#
# Default driver: rack_test (no real browser). This handles all server-rendered
# flows (form submission, redirect, status page) without a browser dependency.
#
# JS driver (:js-tagged specs): headless Chrome via Selenium. The report viewer
# island (React + MapLibre + deck.gl) only renders under real JS, so its system
# spec is tagged :js. selenium-webdriver 4's Selenium Manager auto-provisions a
# matching chromedriver, so no separate install step is needed when Chrome is
# present. When Chrome is unavailable the :js examples are skipped (not failed)
# so the suite still runs in a browserless CI lane.
require "selenium-webdriver"

Capybara.register_driver :headless_chrome do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_argument("--headless=new")
  options.add_argument("--no-sandbox")
  options.add_argument("--disable-dev-shm-usage")
  options.add_argument("--window-size=1400,1000")
  # The viewer island needs a WebGL context (MapLibre + deck.gl). Headless
  # Chrome has no GPU, so force software rendering via SwiftShader/ANGLE so the
  # map + layers actually initialize under test.
  options.add_argument("--use-gl=angle")
  options.add_argument("--use-angle=swiftshader")
  options.add_argument("--enable-unsafe-swiftshader")
  options.add_argument("--ignore-gpu-blocklist")
  Capybara::Selenium::Driver.new(app, browser: :chrome, options: options)
end

Capybara.server = :puma, { Silent: true }

def chrome_available?
  return @chrome_available unless @chrome_available.nil?

  @chrome_available =
    [
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      "/usr/bin/google-chrome",
      "/usr/bin/chromium",
      "/usr/bin/chromium-browser"
    ].any? { |p| File.exist?(p) }
end

RSpec.configure do |config|
  config.before(:each, type: :system) do
    driven_by(:rack_test)
  end

  config.before(:each, type: :system, js: true) do
    skip("headless Chrome not available in this environment") unless chrome_available?

    # Rails 8 + Capybara's Puma server share the test's ActiveRecord connection
    # across threads automatically under transactional fixtures, so the in-test
    # fixture rows are visible to the server thread without a manual connection
    # lock. (Earlier Rails needed a shared-connection monkeypatch; 8.x does not.)
    driven_by(:headless_chrome)
  end
end
