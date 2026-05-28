module Api
  module V1
    # iOS capture upload endpoint (ADR-016). Authenticated by a job-scoped bearer
    # capture_token (24h TTL), NOT the dev-login session. F-03 ships auth + a
    # 200 stub; the real ActiveStorage ingest is F-16.
    class CaptureSessionsController < ApplicationController
      skip_before_action :require_demo_login
      # API clients don't carry a CSRF token; they authenticate by bearer.
      skip_forgery_protection

      before_action :authenticate_capture_token!

      def create
        head :ok
      end

      private

      def authenticate_capture_token!
        job = Job.authenticate_capture_token(bearer_token)
        return if job && job.id == params[:job_id]

        render json: { error: "invalid or expired capture token" }, status: :unauthorized
      end

      def bearer_token
        header = request.authorization.to_s
        return nil unless header.start_with?("Bearer ")

        # `.presence` so a bare "Bearer " (empty token) returns nil, not "" —
        # never let an empty token reach the DB lookup as a blank-string query.
        header.delete_prefix("Bearer ").presence
      end
    end
  end
end
