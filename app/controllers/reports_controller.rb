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
  TOKEN_ACTIONS = %i[show_public download_public_pdf export_public].freeze

  skip_before_action :require_demo_login, only: TOKEN_ACTIONS
  before_action :load_report_by_token, only: TOKEN_ACTIONS

  def show_public
    # Share URLs are bearer credentials; keep them out of search indexes.
    response.set_header("X-Robots-Tag", "noindex")

    @job = @report.job
    @measurement = @job&.latest_measurement
    @public = true
    @viewer_payload = @measurement ? MeasurementViewerSerializer.new(@measurement).as_json : nil
    render "reports/show"
  end

  # Public-share PDF download (token-gated). Knowing the share token IS the
  # access grant; a bad token 404s (not a login redirect) so the share surface
  # never leaks the gated app to recipients. Redirects to a signed Spaces URL.
  def download_public_pdf
    response.set_header("X-Robots-Tag", "noindex")
    # An orphaned share (Report#job nullified by a destroyed Job) is treated like
    # a bad token: 404, not a 500. ReportPdf also guards nil, but stopping here
    # avoids constructing the service for a share that can never resolve.
    return head :not_found if @report.job.nil?

    signed_url = ReportPdf.new(@report.job).render
    response.set_header("Cache-Control", "private, max-age=#{ReportPdf::CACHE_WINDOW.to_i}")
    redirect_to signed_url, allow_other_host: true, status: :see_other
  rescue ReportPdf::Error => e
    Rails.logger.error("[download_public_pdf] #{e.class}: #{e.message}")
    render plain: "Report not ready yet.", status: :unprocessable_content
  end

  # Public, token-gated JSON export (ADR-015, shared/json_export.schema.json).
  # Same serializer output as the auth-required api/v1 export; the only
  # differences are the token-gate (404 on a bad token, head — never a redirect)
  # and the permissive CORS header so browser-based downstream tools can fetch it.
  # A not-ready job (nil measurement) returns 200 with a null measurement, never
  # a 500 (ADR-016 resolver contract).
  def export_public
    job = @report.job

    # An orphaned share token (the report's job was destroyed, nullifying job_id)
    # points at nothing meaningful and cannot produce a valid export document:
    # the export contract requires a non-null job id/status, so emitting a
    # null-job body would fail schema validation and 500 on this anonymous,
    # CORS-open route. Treat it as not-found — the same head-404 a bad token gets.
    return head :not_found if job.nil?

    # Share URLs are bearer credentials — keep them out of search indexes.
    response.set_header("X-Robots-Tag", "noindex")

    hash = JobExportSerializer.new(
      job,
      share_url: public_report_url(token: @report.share_token),
      visualizations: JobVisualizations.for(job)
    ).to_h
    render_validated_export(hash)
  end

  private

  # Resolve the FROZEN shared path token -> Report.find_by!(share_token:) for the
  # public, token-gated actions. A bad token 404s (head, never a redirect to
  # login) so the share surface never leaks the existence of the gated app to
  # recipients. Halts the action chain on a miss.
  def load_report_by_token
    @report = Report.find_by!(share_token: params[:token])
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  # Validate against the frozen public contract before sending. This route is
  # anonymous, so the permissive CORS header is set ONLY on the validated 200
  # path — never on the 500 — so cross-origin JavaScript can never read a
  # schema-validation error body (JSONSchema pointer strings disclose internal
  # field shapes). Serializer drift is a developer-facing bug, so the full
  # errors are logged server-side; the wire response stays terse and detail-free.
  def render_validated_export(hash)
    errors = JsonExportSchema.errors_for(hash)
    if errors.any?
      Rails.logger.error("public JSON export failed schema validation: #{errors.inspect}")
      head :internal_server_error
      return
    end

    # CORS is set in the controller (no rack-cors gem in the Gemfile) so a
    # browser-based estimating tool can fetch the validated export cross-origin.
    response.set_header("Access-Control-Allow-Origin", "*")
    render json: hash, status: :ok
  end
end
