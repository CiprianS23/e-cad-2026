module Gis
  # API pentru grupuri de layere (Layer Manager — folder-like).
  # Persistă starea per `owner_token` din cookie semnat.
  class LayerGroupsController < ApplicationController
    before_action :ensure_owner_token
    before_action :set_group, only: [:update, :destroy]

    # POST /gis/layer_groups
    def create
      max_pos = GisUserLayerGroup.for_owner(@owner_token).maximum(:position) || -1
      group = GisUserLayerGroup.new(
        owner_token: @owner_token,
        name:        params[:name].presence || "Grup nou",
        position:    max_pos + 1,
        collapsed:   false
      )
      if group.save
        render json: group.to_h, status: :created
      else
        render json: { errors: group.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PATCH /gis/layer_groups/:id — redenumire / collapse / reposition
    def update
      if @group.update(group_params)
        render json: @group.to_h
      else
        render json: { errors: @group.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /gis/layer_groups/:id — layerele din grup devin "ungrouped"
    # (FK e ON DELETE SET NULL).
    def destroy
      @group.destroy
      head :no_content
    end

    # POST /gis/layer_groups/reorder
    # body: { order: [id1, id2, id3, ...] } — actualizează `position` la
    # index-ul din array (0..N-1)
    def reorder
      ids = Array(params[:order]).map(&:to_i)
      GisUserLayerGroup.transaction do
        ids.each_with_index do |id, idx|
          GisUserLayerGroup.for_owner(@owner_token).where(id: id).update_all(position: idx)
        end
      end
      head :no_content
    end

    private

    def set_group
      @group = GisUserLayerGroup.for_owner(@owner_token).find(params[:id])
    end

    def group_params
      params.permit(:name, :collapsed, :position)
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
