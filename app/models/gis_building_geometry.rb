# Cache geometric + validări topologice pentru un `Building` digitizat.
# Vezi GisLandGeometry pentru rolul conceptual. Diferența: pe lângă validările
# de topologie, asigură că building.land_id e atribuit din geometry (parcela
# în care cade clădirea) — o clădire NU poate exista fără un Land părinte.
class GisBuildingGeometry < ApplicationRecord
  STATUSES = %w[draft active].freeze
  FACTORY  = RGeo::Cartesian.factory(srid: 3844)

  belongs_to :building

  attr_writer :geom_wkt

  validates :geom,        presence: true
  validates :building_id, uniqueness: true
  validates :status,      inclusion: { in: STATUSES }

  validate  :geom_wkt_parsabil,                if: -> { @geom_wkt.present? }
  validate  :geom_topologic_valid,             if: -> { geom.present? }
  validate  :nu_se_suprapune_cu_alte_cladiri,  if: -> { geom.present? }
  validate  :nu_traverseaza_mai_multe_parcele, if: -> { geom.present? }
  validate  :geom_nu_e_duplicat,               if: -> { geom.present? }
  validate  :land_parinte_atribuit

  before_validation :atribuie_geom_din_wkt,      if: -> { @geom_wkt.present? }
  before_validation :atribuie_land_din_geom,     if: -> { geom.present? && building&.land_id.blank? }
  # before_save fără geom.blank? — pentru save(validate: false) pe UPDATE,
  # geom există DAR trebuie REÎNLOCUIT cu @geom_wkt nou.
  before_save       :atribuie_geom_din_wkt,      if: -> { @geom_wkt.present? }
  before_save       :compute_derived,            if: -> { geom_changed? || new_record? }

  scope :draft,  -> { where(status: "draft") }
  scope :active, -> { where(status: "active") }

  def geom_wkt
    @geom_wkt || geom&.as_text
  end

  def label
    building&.cadgenno.presence || "B##{building_id}"
  end

  private

  def atribuie_geom_din_wkt
    self.geom = FACTORY.parse_wkt(@geom_wkt)
  rescue RGeo::Error::ParseError
    nil
  end

  # Găsește Land-ul (parcela părinte) a cărui geometrie conține cel mai bine
  # poligonul clădirii. Caută în drafturi (gis_land_geometries) prioritar — o
  # clădire digitizată ar trebui să cadă într-o parcelă digitizată.
  def atribuie_land_din_geom
    return unless building
    wkt = geom.as_text
    land_id = self.class.connection.select_value(
      ApplicationRecord.sanitize_sql_array([<<~SQL, wkt, wkt])
        SELECT g.land_id
        FROM gis_land_geometries g
        WHERE ST_Intersects(g.geom, ST_GeomFromText(?, 3844))
        ORDER BY ST_Area(ST_Intersection(g.geom, ST_GeomFromText(?, 3844))) DESC
        LIMIT 1
      SQL
    )
    building.land_id = land_id if land_id
  end

  def land_parinte_atribuit
    return if building&.land_id.present?
    errors.add(:geom, "nu a fost găsită parcela părinte — poligonul clădirii nu se suprapune cu nicio parcelă digitizată")
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
    return if Thread.current[:topology_skip_overlap_check]
    wkt = geom.as_text
    excl = id || 0
    overlaps = self.class.connection.select_all(
      ApplicationRecord.sanitize_sql_array([<<~SQL, wkt, excl, 0.10])
        WITH np AS (SELECT ST_GeomFromText(?, 3844) AS geom)
        SELECT g.id, COALESCE(b.cadgenno, 'B#' || b.id) AS label,
          ROUND(ST_Area(ST_Intersection(g.geom, np.geom))::numeric, 2) AS area
        FROM gis_building_geometries g
        JOIN buildings b ON b.id = g.building_id, np
        WHERE g.id != ?
          AND ST_Intersects(g.geom, np.geom)
          AND ST_Area(ST_Intersection(g.geom, np.geom)) > ?
      SQL
    )
    overlaps.each do |o|
      errors.add(:geom, "se suprapune cu clădirea #{o['label']} (#{o['area']} mp)")
    end
  end

  def nu_traverseaza_mai_multe_parcele
    wkt = geom.as_text
    rows = self.class.connection.select_all(
      ApplicationRecord.sanitize_sql_array([<<~SQL, wkt])
        WITH np AS (SELECT ST_GeomFromText(?, 3844) AS geom),
             vts AS (SELECT (ST_DumpPoints(np.geom)).geom AS pt FROM np)
        SELECT DISTINCT g.land_id, COALESCE(l.cadgenno, 'L#' || l.id) AS label
        FROM gis_land_geometries g
        JOIN lands l ON l.id = g.land_id, vts
        WHERE ST_Intersects(g.geom, vts.pt)
      SQL
    )
    return if rows.length <= 1
    labels = rows.map { |r| r["label"] }.join(", ")
    errors.add(:geom, "vertecșii clădirii sunt în #{rows.length} parcele diferite (#{labels}) — clădirea trebuie încadrată într-o singură parcelă")
  end

  def geom_nu_e_duplicat
    excl = id || 0
    wkt  = geom.as_text
    dup = self.class.connection.select_one(
      ApplicationRecord.sanitize_sql_array([<<~SQL, excl, wkt])
        SELECT g.id, COALESCE(b.cadgenno, 'B#' || b.id) AS label
        FROM gis_building_geometries g
        JOIN buildings b ON b.id = g.building_id
        WHERE g.id != ?
          AND ST_Equals(g.geom, ST_GeomFromText(?, 3844))
        LIMIT 1
      SQL
    )
    errors.add(:geom, "geometrie identică cu clădirea #{dup['label']} există deja — duplicat respins") if dup
  rescue ActiveRecord::StatementInvalid
    # tabelele lipsesc în alt context — ignorăm
  end

  def compute_derived
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
