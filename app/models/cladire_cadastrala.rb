class CladireCadastrala < ApplicationRecord
  self.table_name = "cladiri_cadastrale"

  DESTINATII = %w[locuinte birouri comercial industrial cult invatamant sanatate
                  cultura sport agrement administrativ tehnico_edilitar gospodarie neproductiv].freeze
  STATUSURI  = %w[activ inactiv litigiu].freeze
  FACTORY    = RGeo::Cartesian.factory(srid: 3844)

  belongs_to :parcela_cadastrala, class_name: "ParcelaCadastrala"

  attr_writer :geom_wkt

  validates :numar_cadastral,    presence: true, uniqueness: true
  validates :judet,              presence: true
  validates :localitate,         presence: true
  validates :status,             inclusion: { in: STATUSURI }
  validates :parcela_cadastrala, presence: {
    message: "nu a fost găsită — poligonul clădirii nu se suprapune cu nicio parcelă cadastrală"
  }
  validate  :geom_wkt_parsabil, if: -> { @geom_wkt.present? }

  before_validation :atribuie_geom_din_wkt,     if: -> { @geom_wkt.present? }
  before_validation :atribuie_parcela_din_geom,  if: -> { geom.present? && parcela_cadastrala_id.blank? }
  before_save       :calculeaza_centroid,        if: :geom_changed?

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

  def atribuie_parcela_din_geom
    wkt = @geom_wkt || geom&.as_text
    return unless wkt.present?

    parcela = ParcelaCadastrala
                .where("geom IS NOT NULL AND ST_Intersects(geom, ST_GeomFromText(?, 3844))", wkt)
                .order(Arel.sql("ST_Area(ST_Intersection(geom, ST_GeomFromText(#{ActiveRecord::Base.connection.quote(wkt)}, 3844))) DESC"))
                .first
    self.parcela_cadastrala = parcela
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
