module Api
  module V1
    class BaseController < ApplicationController
      skip_before_action :require_demo_login
      skip_forgery_protection

      before_action :authenticate_app_token!

      private

      attr_reader :current_app_token

      def authenticate_app_token!
        @current_app_token = AppToken.authenticate(bearer_token)
        return if current_app_token

        render json: { error: "authentication required" }, status: :unauthorized
      end

      def bearer_token
        header = request.authorization.to_s
        return nil unless header.start_with?("Bearer ")

        header.delete_prefix("Bearer ").presence
      end
    end
  end
end
