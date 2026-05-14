require "sidekiq/web"

Rails.application.routes.draw do
  mount Sidekiq::Web => "/sidekiq"

  get "up" => "rails/health#show", as: :rails_health_check

  resources :lands do
    collection do
      get :geojson
      get :lookup
    end
    member do
      get :popup_info
    end
  end

  resources :buildings, only: [:show, :create, :update, :destroy] do
    collection do
      get :geojson
    end
    member do
      get :popup_info
    end
  end

  resources :cgxml_imports, only: [ :new, :create ]
  resources :cgxml_bulk_imports, only: [ :new, :create ]

  resources :cgxml_files, only: [ :index, :show ] do
    member do
      post :revalidate
      get  :report
    end
    collection do
      get :comparison
    end
  end

  resources :cgxml_validation_errors, only: [] do
    collection do
      post :validate_field
    end
    member do
      patch :fix
      patch :unfix
    end
  end

  get  "/harta/cgxml_geojson", to: "harta#cgxml_geojson", as: :cgxml_geojson_harta

  scope "/digitizare" do
    post "/calculeaza",       to: "digitizare#calculeaza_suprafata", as: :digitizare_calculeaza
    post "/verifica_topologie", to: "digitizare#verifica_topologie", as: :digitizare_verifica_topologie
    post "/save_batch",         to: "digitizare#save_batch",         as: :digitizare_save_batch
    get  "/audit_topologie",    to: "digitizare#audit_topologie",    as: :digitizare_audit_topologie
    post "/import_dxf",         to: "digitizare#import_dxf",         as: :digitizare_import_dxf
    post "/parse_geo_file",     to: "digitizare#parse_geo_file",     as: :digitizare_parse_geo_file
    post "/export_zone",        to: "digitizare#export_zone",        as: :digitizare_export_zone
    post "/export_dxf",       to: "digitizare#export_dxf",         as: :digitizare_export_dxf
    post "/locate_uat",       to: "digitizare#locate_uat",         as: :digitizare_locate_uat
    post "/locate_parcela",   to: "digitizare#locate_parcela",     as: :digitizare_locate_parcela
  end
  get "/siruta/autocomplete", to: "siruta#autocomplete", as: :siruta_autocomplete

  get "/harta", to: "harta#index", as: :harta
  get "/uat_boundaries/geojson", to: "uat_boundaries#geojson", as: :uat_boundaries_geojson

  # Modul GIS — preferințe Layer Manager + georeferențiere planuri vechi
  namespace :gis do
    get    "/layer_prefs",            to: "layer_prefs#index",       as: :layer_prefs
    patch  "/layer_prefs/:layer_key", to: "layer_prefs#update",      as: :layer_pref
    delete "/layer_prefs",            to: "layer_prefs#destroy_all", as: :reset_layer_prefs

    # Grupuri configurabile pentru Layer Manager (QGIS-like)
    resources :layer_groups, only: [:create, :update, :destroy] do
      collection do
        post :reorder   # body { order: [id1, id2, ...] } → setează `position`
      end
    end

    resources :georef_plans do
      member do
        post :georeference        # recalculează afină rapidă (preview, fără warp)
        post :finalize            # gdalwarp → warped GeoTIFF (state=finalized)
        post :regenerate_preview  # rerun prepare_for_display! (când preview eșuat)
      end
      resources :control_points, only: [:create, :update, :destroy],
                                  controller: :georef_control_points
    end

    # Contururi de lucru pentru divizare proiect (persistente; multiple per utilizator)
    resources :contours, only: [:index, :show, :create, :update, :destroy]

    # Imobile corectate — Faza 2 (CGXML fit) și ulterior Faza 3+
    post "/imobile/fit_preview",      to: "imobile#fit_preview",     as: :imobile_fit_preview
    post "/imobile/fit_apply",        to: "imobile#fit_apply",       as: :imobile_fit_apply
    post "/imobile/remaining_zones",  to: "imobile#remaining_zones", as: :imobile_remaining_zones
    post "/imobile/simulate_fit",     to: "imobile#simulate_fit",    as: :imobile_simulate_fit

    # Proxy WMTS pentru ortofotoplan Sascut (geosys.ro, basic auth).
    # Browser-ul cere tile-uri prin Rails ca să nu expunem credențialele.
    get "/wmts/sascut/:matrix/:col/:row",
        to: "wmts_proxy#sascut",
        as: :gis_wmts_sascut,
        constraints: { matrix: /\d+/, col: /\d+/, row: /\d+/ },
        defaults: { format: :png }
  end

  root "harta#index"
end
