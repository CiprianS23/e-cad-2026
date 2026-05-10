require "sidekiq/web"

Rails.application.routes.draw do
  mount Sidekiq::Web => "/sidekiq"

  get "up" => "rails/health#show", as: :rails_health_check

  resources :parcele_cadastrale do
    collection do
      get :geojson
      get :lookup
    end
  end

  resources :cladiri_cadastrale, only: [:show, :create, :update] do
    collection do
      get :geojson
    end
  end

  resources :cgxml_imports, only: [ :new, :create ]

  resources :cgxml_files, only: [ :index, :show ] do
    member do
      post :revalidate
      get  :report
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
    post "/export_dxf",       to: "digitizare#export_dxf",         as: :digitizare_export_dxf
    post "/locate_uat",       to: "digitizare#locate_uat",         as: :digitizare_locate_uat
    post "/locate_parcela",   to: "digitizare#locate_parcela",     as: :digitizare_locate_parcela
  end
  get "/siruta/autocomplete", to: "siruta#autocomplete", as: :siruta_autocomplete

  get "/harta", to: "harta#index", as: :harta
  get "/uat_boundaries/geojson", to: "uat_boundaries#geojson", as: :uat_boundaries_geojson
  root "harta#index"
end
