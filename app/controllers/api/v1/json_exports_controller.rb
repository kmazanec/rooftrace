module Api
  module V1
    # Auth-required contractor JSON export (ADR-015, shared/json_export.schema.json).
    # Returns the IDENTICAL JobExportSerializer output as the public /r/:token.json
    # route — the only differences are the auth failure mode (401 here vs a
    # token-gate 404 there) and CORS (none here; permissive there). No redaction,
    # no route-conditional serializer branches.
    #
    # The inherited require_demo_login would 302-redirect an unauthenticated
    # request to /login; downstream tools don't follow redirects, so this skips it
    # and answers 401 instead (mirrors CaptureSessionsController's API-style auth).
    class JsonExportsController < ApplicationController
      skip_before_action :require_demo_login

      before_action :require_logged_in_json!

      def show
        job = Job.find_by(id: params[:id])
        return head :not_found if job.nil?

        render_export(JobExportSerializer.new(job, share_url: share_url_for(job)).to_h)
      end

      private

      # The public share identity is part of the export payload, so the two routes
      # must agree on it: when the job has a share Report, inject the same
      # canonical public viewer URL the /r/:token.json route does. Null when the
      # job has no report yet (the public route is unreachable in that case).
      def share_url_for(job)
        report = job.reports.first
        return nil if report.nil?

        public_report_url(token: report.share_token)
      end

      def require_logged_in_json!
        return if logged_in?

        render json: { error: "authentication required" }, status: :unauthorized
      end

      # Validate the serialized document against the public contract before
      # sending it. Serializer drift (a shape that no longer matches the frozen
      # schema) is a developer-facing bug, so it surfaces loudly as a 500 with the
      # error detail rather than shipping a silently-malformed contract document.
      def render_export(hash)
        errors = JsonExportSchema.errors_for(hash)
        if errors.any?
          render json: { error: "export failed schema validation", detail: errors },
                 status: :internal_server_error
          return
        end

        render json: hash, status: :ok
      end
    end
  end
end
