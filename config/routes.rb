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

  get "/harta", to: "harta#index", as: :harta
  root "harta#index"
end
