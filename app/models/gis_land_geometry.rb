# Cache geometric + validări topologice pentru un `Land` în stadiu de digitizare.
#
# Rolul conceptual: un Land cu `gis_geometry.status = 'draft'` este o parcelă
# pre-juridică — geometrie + identificator temporar, fără registrations/persons/deeds.
# Când i se atașează informații juridice, status devine 'active' și Land-ul e
# „imobil" complet. Geometria stă aici (cache MultiPolygon indexat GIST) ca să
# nu fim nevoiți să reconstruim poligonul din `points` la fiecare query spațial.
class GisLandGeometry < ApplicationRecord
  STATUSES = %w[draft active].freeze
  FACTORY  = RGeo::Cartesian.factory(srid: 3844)

  belongs_to :land

  attr_writer :geom_wkt

  validates :geom,    presence: true
  validates :land_id, uniqueness: true
  validates :status,  inclusion: { in: STATUSES }

  validate  :geom_wkt_parsabil,                 if: -> { @geom_wkt.present? }
  validate  :geom_topologic_valid,              if: -> { geom.present? }
  validate  :nu_se_suprapune_cu_alte_parcele,   if: -> { geom.present? }
  validate  :geom_nu_e_duplicat,                if: -> { geom.present? }

  before_validation :atribuie_geom_din_wkt, if: -> { @geom_wkt.present? }
  # before_save fără condiția geom.blank? — pentru save(validate: false) pe
  # UPDATE-uri, geom există DEJA dar trebuie REÎNLOCUIT cu @geom_wkt nou.
  before_save       :atribuie_geom_din_wkt,  if: -> { @geom_wkt.present? }
  before_save       :compute_derived,        if: -> { geom_changed? || new_record? }

  scope :draft,     -> { where(status: "draft") }
  scope :active,    -> { where(status: "active") }

  def geom_wkt
    @geom_wkt || geom&.as_text
  end

  # Eticheta vizibilă pe hartă / în mesaje. Foloseste cadgenno-ul de pe Land
  # (care e și label-ul oficial cgxml); pentru drafturi fără cadgenno cădem pe id.
  def label
    land&.cadgenno.presence || "L##{land_id}"
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

  def nu_se_suprapune_cu_alte_parcele
    return if Thread.current[:topology_skip_overlap_check]
    wkt = geom.as_text
    excl = id || 0
    overlaps = self.class.connection.select_all(
      ApplicationRecord.sanitize_sql_array([<<~SQL, wkt, excl, 0.10])
        WITH np AS (SELECT ST_GeomFromText(?, 3844) AS geom)
        SELECT g.id, COALESCE(l.cadgenno, 'L#' || l.id) AS label,
          ROUND(ST_Area(ST_Intersection(g.geom, np.geom))::numeric, 2) AS area
        FROM gis_land_geometries g
        JOIN lands l ON l.id = g.land_id, np
        WHERE g.id != ?
          AND ST_Intersects(g.geom, np.geom)
          AND ST_Area(ST_Intersection(g.geom, np.geom)) > ?
      SQL
    )
    overlaps.each do |o|
      errors.add(:geom, "se suprapune cu parcela #{o['label']} (#{o['area']} mp)")
    end
  end

  def geom_nu_e_duplicat
    excl = id || 0
    wkt  = geom.as_text
    dup = self.class.connection.select_one(
      ApplicationRecord.sanitize_sql_array([<<~SQL, excl, wkt])
        SELECT g.id, COALESCE(l.cadgenno, 'L#' || l.id) AS label
        FROM gis_land_geometries g
        JOIN lands l ON l.id = g.land_id
        WHERE g.id != ?
          AND ST_Equals(g.geom, ST_GeomFromText(?, 3844))
        LIMIT 1
      SQL
    )
    errors.add(:geom, "geometrie identică cu parcela #{dup['label']} există deja — duplicat respins") if dup
  rescue ActiveRecord::StatementInvalid
    # tabelele lipsesc în alt context — ignorăm
  end

  def compute_derived
    # IMPORTANT: folosim geom.as_text (WKT) în loc de geom_before_type_cast.
    # Pentru MultiPolygon cu mai multe părți, geom_before_type_cast poate
    # serializa virgule între EWKB-uri → SQL primește 2 args la ST_PointOnSurface
    # → eroare "function st_pointonsurface(unknown, geometry) does not exist".
    wkt = geom.as_text
    res = self.class.connection.select_one(
      self.class.sanitize_sql_array([
        "SELECT ST_PointOnSurface(ST_GeomFromText(?, 3844)) AS centroid,
                ROUND(ST_Area(ST_GeomFromText(?, 3844))::numeric, 4) AS area",
        wkt, wkt
      ])
    )
    self.centroid     = res["centroid"]
    self.suprafata_mp = res["area"]
  end
end
