class GisImobil < ApplicationRecord
  self.table_name = "gis_imobile"

  SOURCES = %w[cgxml_fit divizare_zona manual].freeze
  FACTORY = RGeo::Cartesian.factory(srid: 3844)

  belongs_to :land, optional: true, foreign_key: :land_id, class_name: "Land"

  validates :source, inclusion: { in: SOURCES }

  before_save :compute_area_from_geom, if: -> { geom_corrected.present? && geom_corrected_changed? }

  scope :for_cgxml, -> { where(source: "cgxml_fit").where.not(land_id: nil) }
  scope :for_divizare, -> { where(source: "divizare_zona") }

  private

  def compute_area_from_geom
    self.area_corrected = self.class.connection.select_value(
      ApplicationRecord.sanitize_sql_array([
        "SELECT ROUND(ST_Area(ST_GeomFromText(?, 3844))::numeric, 2)",
        geom_corrected.as_text
      ])
    )
  end
end
