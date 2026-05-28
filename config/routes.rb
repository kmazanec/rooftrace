Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # F-01 walking skeleton endpoints.
  get "skeleton" => "skeleton#show", defaults: { format: :json }
  get "health"   => "health#show",   defaults: { format: :json }

  # F-03 auth (ADR-016).
  # Dev login (single shared credential; gates contractor surfaces).
  get  "login"  => "sessions#new",     as: :login
  post "login"  => "sessions#create"
  delete "logout" => "sessions#destroy", as: :logout

  # Contractor submit surface (gated by require_demo_login).
  # F-11 adds :show (status page). The /report route is a stub placeholder
  # for the F-12 web viewer — it's linked from the status page once the job
  # is ready, but the viewer itself is not built until F-12 (will 404 until then).
  resources :jobs, only: %i[new create show] do
    member do
      get :report
    end
  end

  # Opaque public-share report viewer (no login; 404 on a bad token).
  get "r/:token" => "reports#show_public", as: :public_report

  # iOS capture upload, authenticated by the job-scoped bearer capture_token.
  namespace :api do
    namespace :v1 do
      post "capture-sessions/:job_id" => "capture_sessions#create", as: :capture_session
    end
  end

  # Contractor lands on the submit surface after login.
  root "jobs#new"

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # F-04 brand/stylesheet demo pages.
  # _demo is the screen viewer; _demo/print renders the same partial in print layout.
  get "reports/_demo"       => "reports_demo#show",  as: :reports_demo
  get "reports/_demo/print" => "reports_demo#print", as: :reports_demo_print

  # Defines the root path route ("/")
  # root "posts#index"
end
