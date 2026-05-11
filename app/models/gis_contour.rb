class GisContour < ApplicationRecord
  self.table_name = "gis_contours"

  STATES  = %w[open finalized].freeze
  FACTORY = RGeo::Cartesian.factory(srid: 3844)

  attr_writer :geom_wkt

  validates :name,  presence: true, length: { maximum: 120 }
  validates :state, inclusion: { in: STATES }
  validates :owner_token, presence: true
  validate  :geom_present_and_valid

  before_validation :assign_geom_from_wkt, if: -> { @geom_wkt.present? }
  before_save       :compute_area,         if: -> { geom.present? && geom_changed? }

  scope :open_only, -> { where(state: "open") }
  scope :for_owner, ->(token) { where(owner_token: token) }

  def geom_wkt
    @geom_wkt || geom&.as_text
  end

  def geojson_geometry
    return nil unless persisted? && geom
    JSON.parse(self.class.connection.select_value(
      ApplicationRecord.sanitize_sql_array([
        "SELECT ST_AsGeoJSON(geom, 6) FROM gis_contours WHERE id = ?",
        id
      ])
    ))
  end

  private

  def assign_geom_from_wkt
    self.geom = FACTORY.parse_wkt(@geom_wkt)
  rescue RGeo::Error::ParseError
    errors.add(:geom, "WKT invalid")
  end

  def geom_present_and_valid
    if geom.blank?
      errors.add(:geom, "lipsește geometria") and return
    end
    ok = self.class.connection.select_value(
      ApplicationRecord.sanitize_sql_array([
        "SELECT ST_IsValid(ST_GeomFromText(?, 3844))",
        geom.as_text
      ])
    )
    errors.add(:geom, "geometrie invalidă topologic") unless ok
  end

  def compute_area
    self.area = self.class.connection.select_value(
      ApplicationRecord.sanitize_sql_array([
        "SELECT ROUND(ST_Area(ST_GeomFromText(?, 3844))::numeric, 2)",
        geom.as_text
      ])
    )
  end
end
