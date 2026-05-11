module Gis
  class GeorefControlPointsController < ApplicationController
    before_action :ensure_owner_token
    before_action :set_plan
    before_action :set_point, only: [:update, :destroy]

    # POST /gis/georef_plans/:plan_id/control_points
    def create
      cp = @plan.control_points.new(point_params)
      if cp.save
        render json: cp_json(cp), status: :created
      else
        render json: { errors: cp.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PATCH /gis/georef_plans/:plan_id/control_points/:id
    def update
      if @point.update(point_params)
        render json: cp_json(@point)
      else
        render json: { errors: @point.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /gis/georef_plans/:plan_id/control_points/:id
    def destroy
      @point.destroy
      head :no_content
    end

    private

    def set_plan
      @plan = GisGeorefPlan.for_owner(@owner_token).find(params[:georef_plan_id])
    end

    def set_point
      @point = @plan.control_points.find(params[:id])
    end

    def point_params
      params.require(:gis_georef_control_point).permit(:pixel_x, :pixel_y, :world_x, :world_y, :ordinal, :note)
    end

    def cp_json(cp)
      {
        id: cp.id, ordinal: cp.ordinal,
        pixel_x: cp.pixel_x, pixel_y: cp.pixel_y,
        world_x: cp.world_x, world_y: cp.world_y,
        residual: cp.residual, note: cp.note
      }
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
