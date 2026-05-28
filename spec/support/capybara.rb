# Capybara configuration for system specs.
#
# Driver: rack_test (no real browser). This avoids:
#   - Separate-thread transactions conflicting with use_transactional_fixtures
#   - Selenium/Chrome availability requirements in CI
#   - WebSocket-based Turbo Stream updates (covered by model broadcast specs)
#
# rack_test handles all F-11 system tests: form submission, redirect, status
# page rendering. Real-browser tests would be needed only if the spec required
# JavaScript execution — not the case here since all behavior is server-rendered.
RSpec.configure do |config|
  config.before(:each, type: :system) do
    driven_by(:rack_test)
  end
end
