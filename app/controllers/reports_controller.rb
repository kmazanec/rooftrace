# Opaque public-share report viewer (ADR-016). No login: knowing the 32-char
# share token IS the access grant. A bad token 404s (not a redirect to login)
# so the share surface never leaks the existence of the gated app to recipients.
# The real read-only viewer is F-12; this renders a minimal stub.
class ReportsController < ApplicationController
  skip_before_action :require_demo_login, only: :show_public

  def show_public
    @report = Report.find_by!(share_token: params[:token])
    # Share URLs are bearer credentials; keep them out of search indexes.
    response.set_header("X-Robots-Tag", "noindex")
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end
end
