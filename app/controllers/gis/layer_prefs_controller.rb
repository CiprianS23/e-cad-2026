module Gis
  # API pentru preferințe de layer per utilizator (Layer Manager).
  # Folosește un `owner_token` din cookie semnat — la integrare în e-CAD prod
  # se va înlocui cu `current_user.id`.
  class LayerPrefsController < ApplicationController
    before_action :ensure_owner_token

    # GET /gis/layer_prefs
    def index
      render json: { layers: GisUserLayerPref.full_prefs_for(@owner_token) }
    end

    # PATCH /gis/layer_prefs/:layer_key
    def update
      key = params[:layer_key].to_s
      unless GisUserLayerPref::VALID_KEYS.include?(key)
        return render json: { error: "Layer necunoscut: #{key}" }, status: :unprocessable_entity
      end

      pref = GisUserLayerPref.find_or_initialize_by(owner_token: @owner_token, layer_key: key)
      pref.assign_attributes(pref_params)

      if pref.save
        defaults = GisUserLayerPref::DEFAULTS[key]
        render json: { layer: GisUserLayerPref.merged_config(key, defaults, pref) }
      else
        render json: { errors: pref.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /gis/layer_prefs — reset toate preferințele (revine la default)
    def destroy_all
      GisUserLayerPref.for_owner(@owner_token).delete_all
      render json: { layers: GisUserLayerPref.full_prefs_for(@owner_token) }
    end

    private

    def pref_params
      params.permit(:visible, :locked, :opacity,
                    :stroke_color, :fill_color, :stroke_width, :stroke_dash,
                    :z_index, :color_by_category,
                    :min_resolution, :max_resolution)
    end

    # Cookie semnat persistent (1 an), regenerat dacă lipsește.
    # Identificator stabil per browser/sesiune lungă.
    def ensure_owner_token
      cookies.signed[:gis_owner_token] ||= {
        value:    SecureRandom.uuid,
        expires:  1.year.from_now,
        httponly: true
      }
      @owner_token = cookies.signed[:gis_owner_token]
    end
  end
end
