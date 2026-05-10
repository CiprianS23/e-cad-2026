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
  validate  :geom_topologic_valid,                  if: -> { geom.present? }
  validate  :nu_se_suprapune_cu_alte_cladiri,       if: -> { geom.present? }
  validate  :nu_traverseaza_mai_multe_parcele,      if: -> { geom.present? }

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

  def geom_topologic_valid
    wkt = geom.as_text
    row = self.class.connection.select_one(
      ApplicationRecord.sanitize_sql_array([
        "SELECT ST_IsValid(ST_GeomFromText(?, 3844)) AS is_valid, ST_IsValidReason(ST_GeomFromText(?, 3844)) AS reason",
        wkt, wkt
      ])
    )
    return if row["is_valid"]
    errors.add(:geom, "geometrie invalidă topologic: #{row['reason']}")
  end

  def nu_se_suprapune_cu_alte_cladiri
    wkt = geom.as_text
    excl = id || 0
    overlaps = self.class.connection.select_all(
      ApplicationRecord.sanitize_sql_array([<<~SQL, wkt, excl, 0.01])
        WITH np AS (SELECT ST_GeomFromText(?, 3844) AS geom)
        SELECT id, numar_cadastral,
          ROUND(ST_Area(ST_Intersection(geom, np.geom))::numeric, 2) AS area
        FROM cladiri_cadastrale, np
        WHERE geom IS NOT NULL
          AND id != ?
          AND ST_Intersects(geom, np.geom)
          AND ST_Area(ST_Intersection(geom, np.geom)) > ?
      SQL
    )
    overlaps.each do |o|
      errors.add(:geom, "se suprapune cu clădirea #{o['numar_cadastral']} (#{o['area']} mp)")
    end
  end

  def nu_traverseaza_mai_multe_parcele
    wkt = geom.as_text
    rows = self.class.connection.select_all(
      ApplicationRecord.sanitize_sql_array([<<~SQL, wkt])
        WITH np AS (SELECT ST_GeomFromText(?, 3844) AS geom),
             vts AS (SELECT (ST_DumpPoints(np.geom)).geom AS pt FROM np)
        SELECT DISTINCT p.id, p.numar_cadastral
        FROM parcele_cadastrale p, vts
        WHERE p.geom IS NOT NULL AND ST_Intersects(p.geom, vts.pt)
      SQL
    )
    return if rows.size <= 1
    labels = rows.map { |r| r["numar_cadastral"] }.join(", ")
    errors.add(:geom, "vertecșii clădirii sunt în #{rows.size} parcele diferite (#{labels}) — clădirea trebuie încadrată într-o singură parcelă")
  end

  def calculeaza_centroid
    self.centroid = geom.centroid if geom
  end
end
