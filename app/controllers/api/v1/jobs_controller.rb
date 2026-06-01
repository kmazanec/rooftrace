module Api
  module V1
    class JobsController < BaseController
      def index
        jobs = Job.order(created_at: :desc)
        render json: { jobs: jobs.map { |job| JobStatusSerializer.summary(job) } }, status: :ok
      end

      def show
        job = Job.find_by(id: params[:id])
        return head :not_found if job.nil?

        render json: JobStatusSerializer.detail(job), status: :ok
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
