class GisGeorefControlPoint < ApplicationRecord
  # Punct de control (GCP) pentru transformarea unui plan vechi:
  # (pixel_x, pixel_y) pe imaginea sursă ↔ (world_x, world_y) în EPSG:3844.
  belongs_to :gis_georef_plan, class_name: "GisGeorefPlan"

  validates :pixel_x, :pixel_y, :world_x, :world_y, presence: true, numericality: true
  validates :ordinal, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  before_validation :assign_default_ordinal, on: :create

  def assign_default_ordinal
    self.ordinal ||= (gis_georef_plan&.control_points&.maximum(:ordinal) || -1) + 1
  end
end
