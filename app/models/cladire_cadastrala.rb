class CladireCadastrala < ApplicationRecord
  self.table_name = "cladiri_cadastrale"

  DESTINATII = %w[locuinte birouri comercial industrial cult invatamant sanatate
                  cultura sport agrement administrativ tehnico_edilitar gospodarie neproductiv].freeze
  STATUSURI  = %w[activ inactiv litigiu].freeze
  FACTORY    = RGeo::Cartesian.factory(srid: 3844)

  attr_writer :geom_wkt

  validates :numar_cadastral, presence: true, uniqueness: true
  validates :judet,           presence: true
  validates :localitate,      presence: true
  validates :status,          inclusion: { in: STATUSURI }
  validate  :geom_wkt_parsabil, if: -> { @geom_wkt.present? }

  before_validation :atribuie_geom_din_wkt, if: -> { @geom_wkt.present? }
  before_save       :calculeaza_centroid,   if: :geom_changed?

  scope :active,   -> { where(status: "activ") }
  scope :in_judet, ->(judet) { where(judet: judet) }

  def geom_wkt
    @geom_wkt || geom&.as_text
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
