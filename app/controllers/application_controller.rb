class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # The single dev login gates contractor-facing (submit) surfaces (ADR-016).
  # Public-share routes (/r/:token), the login pages, the iOS capture API, and
  # the health endpoints opt out via `skip_before_action :require_demo_login`.
  before_action :require_demo_login

  private

  def require_demo_login
    return if session[:demo_logged_in]

    # Remember where to send the user back to after login, but only for
    # navigations (GET/HEAD) — never stash a POST/PUT/DELETE target.
    session[:return_to] = request.fullpath if request.get? || request.head?
    redirect_to login_path
  end

  def logged_in?
    session[:demo_logged_in].present?
  end
  helper_method :logged_in?
end
