module Api
  module V1
    class SessionsController < ApplicationController
      skip_before_action :require_demo_login
      skip_forgery_protection

      def create
        unless DemoCredential.valid?(params[:username], params[:password])
          render json: { error: "invalid credentials" }, status: :unauthorized
          return
        end

        app_token = AppToken.create!
        render json: {
          app_token: app_token.token,
          expires_at: app_token.expires_at.iso8601
        }, status: :created
      end
    end
  end
end
