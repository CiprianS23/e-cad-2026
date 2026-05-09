class ParcelaCadastrala < ApplicationRecord
  self.table_name = "parcele_cadastrale"

  CATEGORII_FOLOSINTA = %w[arabil pasune faneata vie livada padure curti_constructii ape neproductiv].freeze
  STATUSURI           = %w[activ inactiv litigiu].freeze
  FACTORY             = RGeo::Cartesian.factory(srid: 3844)

  attr_writer :geom_wkt

  validates :numar_cadastral,     presence: true, uniqueness: true
  validates :categoria_folosinta, presence: true, inclusion: { in: CATEGORII_FOLOSINTA }
  validates :judet,               presence: true
  validates :localitate,          presence: true
  validates :status,              inclusion: { in: STATUSURI }
  validate  :geom_wkt_parsabil,   if: -> { @geom_wkt.present? }

  before_validation :atribuie_geom_din_wkt, if: -> { @geom_wkt.present? }
  before_save       :calculeaza_centroid,    if: :geom_changed?

  scope :active,   -> { where(status: "activ") }
  scope :in_judet, ->(judet) { where(judet: judet) }
  scope :contine_punct, ->(x, y) {
    where("ST_Contains(geom, ST_SetSRID(ST_MakePoint(?, ?), 3844))", x.to_f, y.to_f)
  }

  def geom_wkt
    @geom_wkt || geom&.as_text
  end

  def centroid_latlng
    return nil unless persisted? && centroid
    row = self.class
              .select("ST_Y(ST_Transform(centroid, 4326)) AS lat, ST_X(ST_Transform(centroid, 4326)) AS lng")
              .where(id: id).first
    [row.lat.to_f, row.lng.to_f]
  end

  def geojson_wgs84
    return nil unless persisted? && geom
    self.class.connection.select_value(
      "SELECT ST_AsGeoJSON(ST_Transform(geom, 4326), 6) FROM parcele_cadastrale WHERE id = #{id}"
    )
  end

  private

  def atribuie_geom_din_wkt
    self.geom = FACTORY.parse_wkt(@geom_wkt)
  rescue RGeo::Error::ParseError
    nil
  end

  def geom_wkt_parsabil
    FACTORY.parse_wkt(@geom_wkt)
  rescue RGeo::Error::ParseError
    errors.add(:geom, "WKT invalid — verificați formatul și SRID-ul (Stereo 70 / 3844)")
  end

  def calculeaza_centroid
    self.centroid = geom.centroid if geom
  end
end
