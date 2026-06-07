module Api
  module V1
    class JobsController < BaseController
      include LidarPointsResponder

      def index
        jobs = Job.order(created_at: :desc)
        render json: { jobs: jobs.map { |job| JobStatusSerializer.summary(job) } }, status: :ok
      end

      def show
        job = Job.find_by(id: params[:id])
        return head :not_found if job.nil?

        render json: JobStatusSerializer.detail(job), status: :ok
      end

      # Decimated LiDAR point cloud for the native 3D viewer. App-authed twin of
      # the web's report/lidar_points; delegates to the shared responder, which
      # proxies the sidecar and never 5xxes (404 only for an unknown job).
      def lidar_points
        job = Job.find_by(id: params[:id])
        return head :not_found if job.nil?

        render_lidar_points(job.latest_measurement)
      end

      def create
        job = Job.new(address: params[:address].to_s)

        if job.save
          GeometryJob.perform_later(job.id)
          render json: {
            job_id: job.id,
            capture_token: job.capture_token,
            capture_token_expires_at: job.capture_token_expires_at.iso8601
          }, status: :created
        else
          render json: { errors: job.errors.full_messages }, status: :unprocessable_content
        end
      end
    end
  end
end
