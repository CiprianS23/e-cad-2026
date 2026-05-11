module Gis
  # API pentru preferințe de layer per utilizator (Layer Manager).
  # Folosește un `owner_token` din cookie semnat — la integrare în e-CAD prod
  # se va înlocui cu `current_user.id`.
  class LayerPrefsController < ApplicationController
    before_action :ensure_owner_token

    # GET /gis/layer_prefs
    def index
      render json: GisUserLayerPref.full_state_for(@owner_token)
    end

    # PATCH /gis/layer_prefs/:layer_key
    def update
      key = params[:layer_key].to_s
      unless GisUserLayerPref.valid_key?(key)
        return render json: { error: "Layer necunoscut: #{key}" }, status: :unprocessable_entity
      end

      pref = GisUserLayerPref.find_or_initialize_by(owner_token: @owner_token, layer_key: key)
      pref.assign_attributes(pref_params)

      if pref.save
        defaults = resolve_defaults(key)
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

    # Default-ul pentru cheia primită — static din DEFAULTS sau dinamic pentru
    # planuri raster georef (`georef_plan_<id>`).
    def resolve_defaults(key)
      return GisUserLayerPref::DEFAULTS[key] if GisUserLayerPref::DEFAULTS.key?(key)
      if (m = key.match(GisUserLayerPref::GEOREF_PLAN_KEY_RE))
        plan = GisGeorefPlan.for_owner(@owner_token).find_by(id: m[1].to_i)
        return GisUserLayerPref.georef_plan_defaults(plan) if plan
      end
      {}
    end

    def pref_params
      # group_id: trimitem `null` ca să scoatem layer-ul din grup; `nil` în params
      # nu funcționează direct cu .permit, deci permitem string și-l convertim.
      cleaned = params.permit(:visible, :locked, :opacity,
                              :stroke_color, :fill_color, :stroke_width, :stroke_dash,
                              :z_index, :color_by_category, :bg_transparent, :group_id,
                              :min_resolution, :max_resolution).to_h
      cleaned[:group_id] = nil if cleaned.key?(:group_id) && cleaned[:group_id].blank?
      cleaned
    end

    # Cookie semnat persistent (1 an), regenerat dacă lipsește.
    # Identificator stabil per browser/sesiune lungă.
    def ensure_owner_token
      if Rails.env.development?
        @owner_token = "dev-shared"
        return
      end
      cookies.signed[:gis_owner_token] ||= {
        value:    SecureRandom.uuid,
        expires:  1.year.from_now,
        httponly: true
      }
      @owner_token = cookies.signed[:gis_owner_token]
    end
  end
end
