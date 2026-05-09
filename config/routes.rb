require "sidekiq/web"

Rails.application.routes.draw do
  mount Sidekiq::Web => "/sidekiq"

  get "up" => "rails/health#show", as: :rails_health_check

  resources :parcele_cadastrale do
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
    get  "/",                 to: "digitizare#index",              as: :digitizare
    post "/calculeaza",       to: "digitizare#calculeaza_suprafata", as: :digitizare_calculeaza
    post "/export_dxf",       to: "digitizare#export_dxf",         as: :digitizare_export_dxf
  end
  get "/harta", to: "harta#index", as: :harta
  root "harta#index"
end
