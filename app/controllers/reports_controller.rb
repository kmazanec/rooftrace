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
  skip_before_action :require_demo_login, only: %i[show_public download_public_pdf]

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

  # Public-share PDF download (token-gated). Knowing the share token IS the
  # access grant; a bad token 404s (not a login redirect) so the share surface
  # never leaks the gated app to recipients. Redirects to a signed Spaces URL.
  def download_public_pdf
    report = Report.find_by!(share_token: params[:token])
    response.set_header("X-Robots-Tag", "noindex")
    # An orphaned share (Report#job nullified by a destroyed Job) is treated like
    # a bad token: 404, not a 500. ReportPdf also guards nil, but stopping here
    # avoids constructing the service for a share that can never resolve.
    return head :not_found if report.job.nil?

    signed_url = ReportPdf.new(report.job).render
    response.set_header("Cache-Control", "private, max-age=#{ReportPdf::CACHE_WINDOW.to_i}")
    redirect_to signed_url, allow_other_host: true, status: :see_other
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue ReportPdf::Error => e
    Rails.logger.error("[download_public_pdf] #{e.class}: #{e.message}")
    render plain: "Report not ready yet.", status: :unprocessable_content
  end
end
