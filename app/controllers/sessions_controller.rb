require "bcrypt"

# The single dev login (ADR-016). No User model — the credential is a pair of
# env vars (DEMO_USERNAME + DEMO_PASSWORD_DIGEST, the latter a bcrypt digest).
# A correct login sets a session flag; that's the whole auth state.
class SessionsController < ApplicationController
  skip_before_action :require_demo_login, only: %i[new create]

  # Full-bleed split-screen sign-in (see app/views/layouts/auth.html.erb).
  # create re-renders :new on a bad credential, so it needs the layout too.
  layout "auth", only: %i[new create]

  def new
    redirect_to(after_login_path) and return if logged_in?
  end

  def create
    if valid_credentials?(params[:username], params[:password])
      destination = session[:return_to] || root_path
      # Rotate the session id on privilege escalation to defeat session fixation
      # (a pre-login cookie must not carry into the authenticated session).
      reset_session
      session[:demo_logged_in] = true
      redirect_to destination
    else
      # 200 (not 401) so the login form stays discoverable for the demo.
      flash.now[:alert] = "Incorrect username or password."
      render :new, status: :ok
    end
  end

  def destroy
    reset_session
    redirect_to login_path
  end

  private

  def after_login_path
    session.delete(:return_to) || root_path
  end

  def valid_credentials?(username, password)
    expected_username = ENV["DEMO_USERNAME"].to_s
    digest = ENV["DEMO_PASSWORD_DIGEST"].to_s
    return false if expected_username.empty? || digest.empty?

    # Constant-time username comparison, then bcrypt for the password.
    username_ok = ActiveSupport::SecurityUtils.secure_compare(username.to_s, expected_username)
    password_ok = bcrypt_matches?(digest, password.to_s)
    username_ok && password_ok
  end

  def bcrypt_matches?(digest, password)
    BCrypt::Password.new(digest) == password
  rescue BCrypt::Errors::InvalidHash
    # A malformed DEMO_PASSWORD_DIGEST must never authenticate anyone.
    false
  end
end
