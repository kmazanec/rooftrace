Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Walking-skeleton endpoints.
  get "skeleton" => "skeleton#show", defaults: { format: :json }
  get "health"   => "health#show",   defaults: { format: :json }

  # Auth (ADR-016).
  # Dev login (single shared credential; gates contractor surfaces).
  get  "login"  => "sessions#new",     as: :login
  post "login"  => "sessions#create"
  delete "logout" => "sessions#destroy", as: :logout

  # Address-entry typeahead proxy (gated by require_demo_login). Same-origin so
  # the Mapbox token stays server-side; returns trimmed suggestions as JSON.
  # ADR-004 (amended): Mapbox /suggest provides in-session, non-persisted
  # typeahead only; Nominatim remains the authoritative geocoder.
  get "address_suggestions" => "address_suggestions#index", defaults: { format: :json }

  # Contractor submit surface (gated by require_demo_login).
  # :show is the status page. The /report route is a stub placeholder for the
  # web viewer (ADR-013) — it's linked from the status page once the job is
  # ready, but the viewer itself is not built yet (will 404 until then).
  resources :jobs, only: %i[new create show] do
    member do
      # Authenticated PDF download (require_demo_login). Redirects to a signed
      # Spaces URL over artifacts/<job_id>/report.pdf. Declared BEFORE :report
      # with `format: false` so "/jobs/:id/report.pdf" matches this action
      # rather than the :report viewer stub with a :pdf format.
      get :report_pdf, path: "report.pdf", format: false
      get :report
      # LiDAR point-cloud overlay data for the interactive viewer (ADR-013),
      # lazily fetched when the overlay toggle is switched on.
      get :lidar_points, path: "report/lidar_points", defaults: { format: :json }
      # Reconcile-on-connect: returns the current per-job status partial so the
      # status page can render live state even if its Turbo Stream subscription
      # was established AFTER the pipeline's broadcast already fired (the
      # broadcast race — see JobsController#status).
      get :status
    end
  end

  # Public-share PDF download (token-gated; 404 on a bad token, noindex).
  # Declared BEFORE the generic viewer route so "/r/<token>.pdf" matches the PDF
  # action rather than the viewer with a :pdf format (which would 406).
  # `format: false` keeps ".pdf" a path literal and stops Rails parsing it as a
  # response format that would then need a :pdf responder.
  get "r/:token.pdf" => "reports#download_public_pdf", as: :public_report_pdf, format: false

  # Public, token-gated JSON export (ADR-015). A distinct, explicit `.json` path
  # (declared BEFORE the HTML show_public route) so `/r/:token.json` routes here
  # while `/r/:token` (no extension) still hits the HTML viewer below — a format
  # *default* alone would also capture the extension-less HTML request, so the
  # `.json` is baked into the path. Permissive CORS + noindex; returns the same
  # serializer output as the auth-required api/v1 export.
  get "r/:token.json" => "reports#export_public", as: :public_report_export,
                         format: false, defaults: { format: :json }

  # Public, token-gated LiDAR overlay data (ADR-013). A distinct literal path
  # segment declared BEFORE the generic viewer route so "/r/<token>/lidar_points"
  # matches this action rather than being swallowed by "r/:token". 404 on a bad
  # token (via the controller before_action); lazily fetched by the viewer.
  get "r/:token/lidar_points" => "reports#lidar_points_public",
                                 as: :public_report_lidar_points, defaults: { format: :json }

  # Opaque public-share report viewer (no login; 404 on a bad token).
  get "r/:token" => "reports#show_public", as: :public_report

  # iOS capture upload, authenticated by the job-scoped bearer capture_token.
  namespace :api do
    namespace :v1 do
      post "sessions" => "sessions#create"
      post "capture-sessions/:job_id" => "capture_sessions#create", as: :capture_session

      # Auth-required contractor JSON export (ADR-015). 401 (not a 302 redirect)
      # when unauthenticated so downstream tools that don't follow redirects fail
      # cleanly. Locked down — no CORS header.
      get "jobs/:id.json" => "json_exports#show", as: :job_export,
                              format: false, defaults: { format: :json }
      get "jobs" => "jobs#index", defaults: { format: :json }
      post "jobs" => "jobs#create", defaults: { format: :json }
      get "jobs/:id" => "jobs#show", defaults: { format: :json }
    end
  end

  # Contractor lands on the submit surface after login.
  root "jobs#new"

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Brand/stylesheet demo pages.
  # _demo is the screen viewer; _demo/print renders the same partial in print layout.
  get "reports/_demo"       => "reports_demo#show",  as: :reports_demo
  get "reports/_demo/print" => "reports_demo#print", as: :reports_demo_print

  # Defines the root path route ("/")
  # root "posts#index"
end
