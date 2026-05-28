# Opaque public-share report viewer (ADR-016). No login: knowing the 32-char
# share token IS the access grant. A bad token 404s (not a redirect to login)
# so the share surface never leaks the existence of the gated app to recipients.
#
# Resolves the FROZEN shared path: token -> Report.find_by!(share_token:) ->
# report.job -> job.latest_measurement (live, never a snapshot). A nil job or no
# measurement renders a not-ready state (never a 500); a bad token 404s (never a
# redirect). The read-only viewer renders the SAME shared template as the
# contractor view, differing only in the @public chrome flag.
class ReportsController < ApplicationController
  skip_before_action :require_demo_login, only: :show_public

  def show_public
    @report = Report.find_by!(share_token: params[:token])
    # Share URLs are bearer credentials; keep them out of search indexes.
    response.set_header("X-Robots-Tag", "noindex")

    @job = @report.job
    @measurement = @job&.latest_measurement
    @public = true
    @viewer_payload = @measurement ? MeasurementViewerSerializer.new(@measurement).as_json : nil
    render "reports/show"
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end
end
