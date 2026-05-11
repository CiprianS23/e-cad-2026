module Gis
  class ContoursController < ApplicationController
    protect_from_forgery with: :null_session, if: -> { request.format.json? }
    before_action :ensure_owner_token

    def index
      list = GisContour.for_owner(@owner_token).open_only.order(updated_at: :desc)
      render json: { contours: list.map { |c| serialize(c, with_geom: true) } }
    end

    def show
      c = GisContour.for_owner(@owner_token).find(params[:id])
      render json: { contour: serialize(c, with_geom: true) }
    end

    def create
      c = GisContour.new(contour_params.merge(owner_token: @owner_token, state: "open"))
      if c.save
        render json: { ok: true, contour: serialize(c, with_geom: true) }
      else
        render json: { ok: false, errors: c.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def update
      c = GisContour.for_owner(@owner_token).find(params[:id])
      if c.update(contour_params)
        render json: { ok: true, contour: serialize(c, with_geom: true) }
      else
        render json: { ok: false, errors: c.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def destroy
      c = GisContour.for_owner(@owner_token).find(params[:id])
      c.destroy
      render json: { ok: true }
    end

    private

    def contour_params
      params.permit(:name, :state, :geom_wkt, :notes)
    end

    def serialize(c, with_geom: false)
      h = {
        id:         c.id,
        name:       c.name,
        state:      c.state,
        area:       c.area&.to_f,  # DECIMAL → Float pentru JSON, evită string în client
        updated_at: c.updated_at
      }
      h[:geometry] = c.geojson_geometry if with_geom
      h
    end

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
