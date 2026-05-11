module Gis
  class GeorefPlansController < ApplicationController
    before_action :ensure_owner_token
    before_action :set_plan, only: [:show, :update, :destroy, :georeference, :edit, :finalize, :regenerate_preview]

    # GET /gis/georef_plans
    def index
      plans = GisGeorefPlan.for_owner(@owner_token).order(updated_at: :desc)
      respond_to do |format|
        format.json { render json: plans.map { |p| plan_summary(p) } }
        format.html # listă în UI
      end
    end

    # GET /gis/georef_plans/new
    def new
      @plan = GisGeorefPlan.new
    end

    # POST /gis/georef_plans
    def create
      plan = GisGeorefPlan.new(plan_params.merge(owner_token: @owner_token, state: "draft"))
      file = params.dig(:gis_georef_plan, :raster_file)
      plan.raster_file.attach(file) if file.present?

      if plan.save
        # Generăm preview (din TIFF/PDF) + citim dimensiunile reale.
        # Sincronă — pentru >100 MB ar trebui Sidekiq.
        preview_error = nil
        if plan.raster_file.attached?
          begin
            plan.prepare_for_display!
          rescue Gis::RasterPreviewer::PreviewError => e
            preview_error = "Preview-ul nu s-a putut genera: #{e.message}. Verifică în Rails log."
          end
        end
        notice = "Plan încărcat. Adaugă puncte de control pentru georeferențiere."
        notice += " ⚠ " + preview_error if preview_error
        redirect_to edit_gis_georef_plan_path(plan), notice: notice
      else
        flash.now[:alert] = plan.errors.full_messages.join(", ")
        @plan = plan
        render :new, status: :unprocessable_entity
      end
    end

    # GET /gis/georef_plans/:id
    def show
      render json: plan_full(@plan)
    end

    # GET /gis/georef_plans/:id/edit — ecranul de georeferențiere (dual-viewport)
    def edit
    end

    # PATCH /gis/georef_plans/:id
    def update
      if @plan.update(plan_params)
        render json: plan_summary(@plan)
      else
        render json: { errors: @plan.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # POST /gis/georef_plans/:id/georeference — recalculează transformarea afină
    # (preview rapid în browser, fără warp).
    def georeference
      result = @plan.recompute_georeference!
      if result[:ok]
        render json: plan_full(@plan).merge(rms: result[:rms])
      else
        render json: { error: result[:error] }, status: :unprocessable_entity
      end
    end

    # POST /gis/georef_plans/:id/finalize — rulează gdalwarp pentru a produce
    # un GeoTIFF georeferențiat efectiv (cu corecție polinomială sau TPS).
    # După succes: state = "finalized", warped_file atașat.
    def finalize
      method = params[:method].presence || "auto"
      unless GisGeorefPlan::WARP_METHODS.include?(method)
        return render json: { error: "Metodă invalidă: #{method}. Opțiuni: #{GisGeorefPlan::WARP_METHODS.join(', ')}" },
                      status: :unprocessable_entity
      end

      result = @plan.finalize_warp!(method: method)
      if result[:ok]
        render json: plan_full(@plan).merge(warp_result: result.except(:ok))
      else
        render json: { error: result[:error] }, status: :unprocessable_entity
      end
    end

    # DELETE /gis/georef_plans/:id
    def destroy
      name = @plan.name
      @plan.destroy
      respond_to do |format|
        format.html { redirect_to gis_georef_plans_path, status: :see_other, notice: "Plan „#{name}” șters." }
        format.json { head :no_content }
      end
    end

    # POST /gis/georef_plans/:id/regenerate_preview
    # Reapelează prepare_for_display! — util când preview-ul inițial a eșuat.
    def regenerate_preview
      @plan.prepare_for_display!
      render json: { ok: true, preview_url: @plan.raster_preview_url }
    rescue Gis::RasterPreviewer::PreviewError => e
      render json: { ok: false, error: e.message }, status: :unprocessable_entity
    end

    private

    def set_plan
      @plan = GisGeorefPlan.for_owner(@owner_token).find(params[:id])
    end

    def plan_params
      params.require(:gis_georef_plan).permit(:name, :description, :original_width, :original_height, :state)
    end

    def plan_summary(p)
      {
        id:               p.id,
        name:             p.name,
        description:      p.description,
        state:            p.state,
        residual_rms:     p.residual_rms,
        original_width:   p.original_width,
        original_height:  p.original_height,
        raster_url:       p.raster_url,
        warped_url:       p.warped_url,
        display_url:      p.display_url,
        control_points_count: p.control_points.count,
        updated_at:       p.updated_at
      }
    end

    def plan_full(p)
      plan_summary(p).merge(
        transform_type:   p.transform_type,
        transform_params: p.transform_params,
        corners_world:    p.display_corners_world,
        bounds_extent:    p.bounds_extent_3844,
        control_points:   p.control_points.map do |cp|
          {
            id:       cp.id,
            ordinal:  cp.ordinal,
            pixel_x:  cp.pixel_x,
            pixel_y:  cp.pixel_y,
            world_x:  cp.world_x,
            world_y:  cp.world_y,
            residual: cp.residual,
            note:     cp.note
          }
        end
      )
    end

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
