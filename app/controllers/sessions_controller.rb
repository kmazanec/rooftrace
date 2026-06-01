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
    if DemoCredential.valid?(params[:username], params[:password])
      # Capture the post-login destination before reset_session wipes it.
      destination = after_login_path
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
end
