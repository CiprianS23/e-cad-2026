class Point < ApplicationRecord
  FACTORY = RGeo::Cartesian.factory(srid: 3844)

  belongs_to :land,     optional: true
  belongs_to :building, optional: true

  before_save :compute_coordinates

  validates :x, numericality: true, allow_nil: true
  validates :y, numericality: true, allow_nil: true

  private

  def compute_coordinates
    return unless x.present? && y.present?
    self.coordinates = FACTORY.point(x, y)
  end
end
