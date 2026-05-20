# Servește vector tiles (MVT) pentru layere de geometrii. Reutilizează exact
# același tile grid ca raster basemap → tile (z, x, y) acoperă același bbox
# geografic atât pentru raster cât și pentru vector. Vezi `TileGrid` și
# `stereoGrid` din harta_map_controller.js.
#
# Pentru un tile request, controller-ul:
#   1) calculează bbox-ul în EPSG:3844 metri din (z, x, y)
#   2) rulează SQL specifice layer-ului filtrat cu `ST_Intersects(geom, bbox)`
#   3) wrap-uiește rezultatul cu `ST_AsMVT(ST_AsMVTGeom(...))` → blob binar MVT
#   4) răspunde cu Content-Type MVT + cache headers
#
# Caching: HTTP `Cache-Control: public, max-age=3600`. Pentru invalidare la
# modificare → bump global version în URL (`?v=<timestamp>`). Pentru moment
# fără ETag granular per-tile (simplitate).
class TilesController < ApplicationController
  # MVT extent in tile coordinates (standard 4096). Buffer = 64 pentru a
  # permite etichete + outline pe muchia tile-ului fără tăiere bruscă.
  MVT_EXTENT = 4096
  MVT_BUFFER = 64

  LAYER_REGISTRY = %w[parcele cladiri cgxml uat].freeze

  def show
    layer = params[:layer]
    return head(:not_found) unless LAYER_REGISTRY.include?(layer)

    z = params[:z].to_i
    x = params[:x].to_i
    y = params[:y].to_i

    bbox = TileGrid.bbox(z, x, y)
    return head(:bad_request) if bbox.nil?

    mvt_blob = build_mvt(layer, bbox)

    response.headers["Cache-Control"] = "public, max-age=3600"
    # MVT este binar — folosim send_data ca Rails să nu încerce să-l encodeze.
    send_data(mvt_blob || "", type: "application/vnd.mapbox-vector-tile", disposition: "inline")
  end

  private

  def build_mvt(layer, bbox)
    bbox_sql = "ST_MakeEnvelope(#{bbox.join(', ')}, 3844)"
    layer_sql = send("#{layer}_source_sql", bbox_sql)

    # Wrap într-un singur SELECT care produce MVT binar. ST_AsMVTGeom
    # convertește din EPSG:3844 metri în coordonate tile (0..4096) + clip.
    sql = <<~SQL
      WITH src AS (
        #{layer_sql}
      ),
      mvtgeom AS (
        SELECT
          ST_AsMVTGeom(src.geom, #{bbox_sql}, #{MVT_EXTENT}, #{MVT_BUFFER}, true) AS geom,
          #{select_props_for(layer)}
        FROM src
        WHERE src.geom IS NOT NULL AND src.geom && #{bbox_sql}
      )
      SELECT ST_AsMVT(mvtgeom.*, '#{layer}', #{MVT_EXTENT}, 'geom') AS mvt
      FROM   mvtgeom
    SQL

    raw = ActiveRecord::Base.connection.select_value(sql)
    # PostgreSQL bytea în mod text → string "\\x..." (hex escaped). Convertim
    # la bytes binari pentru a livra MVT corect către client.
    if raw.is_a?(String) && raw.start_with?("\\x")
      [raw[2..]].pack("H*").force_encoding("ASCII-8BIT")
    else
      raw
    end
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.error("Tile #{layer} bbox=#{bbox.inspect}: #{e.message}")
    nil
  end

  def select_props_for(layer)
    case layer
    when "parcele"
      "src.id, src.cadgenno, src.measuredarea, src.isnew, src.status"
    when "cladiri"
      "src.id, src.cadgenno, src.buildno, src.buildingdestination, src.levelsno, src.status, src.land_id"
    when "cgxml"
      "src.entity_type, src.id, src.cadgenno, src.file_description_id, src.validation_status, src.fileversion"
    when "uat"
      "src.id, src.nat_code, src.name"
    end
  end

  # ── SQL per layer ─────────────────────────────────────────────────────────
  # Fiecare returnează SELECT cu `geom` (EPSG:3844) + coloane proprietăți.
  # Filtrul bbox e aplicat în CTE-ul mvtgeom (mai sus), dar la sursele cu
  # subqueries grele (puncte → poligon reconstruit) filtrăm și în interior
  # ca să nu prelucrăm zone irelevante.

  def parcele_source_sql(bbox_sql)
    # gis_land_geometries (cache rapid) + reconstrucție din points pentru
    # lands cgxml fără cache. Pattern identic cu harta_controller#build_cgxml_geojson.
    <<~SQL
      SELECT l.id AS id,
             l.cadgenno AS cadgenno,
             l.measuredarea AS measuredarea,
             l.isnew AS isnew,
             g.status::text AS status,
             g.geom AS geom
      FROM   gis_land_geometries g
      JOIN   lands l ON l.id = g.land_id
      WHERE  g.geom && #{bbox_sql}
      UNION ALL
      SELECT l.id, l.cadgenno, l.measuredarea, l.isnew,
             NULL::text AS status,
             CASE WHEN ST_IsClosed(ll.line)
                  THEN ST_MakePolygon(ll.line)
                  ELSE ST_MakePolygon(ST_AddPoint(ll.line, ST_StartPoint(ll.line)))
             END AS geom
      FROM   (
        SELECT land_id, ST_MakeLine(coordinates ORDER BY no) AS line
        FROM   points
        WHERE  land_id IS NOT NULL AND coordinates IS NOT NULL
          AND  NOT EXISTS (SELECT 1 FROM gis_land_geometries gg WHERE gg.land_id = points.land_id)
        GROUP  BY land_id
        HAVING COUNT(*) >= 3
      ) ll
      JOIN   lands l ON l.id = ll.land_id
      WHERE  ll.line && #{bbox_sql}
    SQL
  end

  def cladiri_source_sql(bbox_sql)
    <<~SQL
      SELECT b.id AS id,
             b.cadgenno AS cadgenno,
             b.buildno AS buildno,
             b.buildingdestination AS buildingdestination,
             b.levelsno AS levelsno,
             g.status::text AS status,
             b.land_id AS land_id,
             g.geom AS geom
      FROM   gis_building_geometries g
      JOIN   buildings b ON b.id = g.building_id
      WHERE  g.geom && #{bbox_sql}
      UNION ALL
      SELECT b.id, b.cadgenno, b.buildno, b.buildingdestination, b.levelsno,
             NULL::text AS status, b.land_id,
             CASE WHEN ST_IsClosed(bl.line)
                  THEN ST_MakePolygon(bl.line)
                  ELSE ST_MakePolygon(ST_AddPoint(bl.line, ST_StartPoint(bl.line)))
             END AS geom
      FROM   (
        SELECT building_id, ST_MakeLine(coordinates ORDER BY no) AS line
        FROM   points
        WHERE  building_id IS NOT NULL AND coordinates IS NOT NULL
          AND  NOT EXISTS (SELECT 1 FROM gis_building_geometries gg WHERE gg.building_id = points.building_id)
        GROUP  BY building_id
        HAVING COUNT(*) >= 3
      ) bl
      JOIN   buildings b ON b.id = bl.building_id
      WHERE  bl.line && #{bbox_sql}
    SQL
  end

  # CGXML = entități importate (lands + buildings) din fișiere CGXML. Servim
  # AMBELE entități prin acest layer (front-end le distinge prin entity_type).
  def cgxml_source_sql(bbox_sql)
    <<~SQL
      SELECT 'land'::text AS entity_type,
             l.id AS id, l.cadgenno AS cadgenno,
             l.file_description_id AS file_description_id,
             fd.validation_status AS validation_status,
             fd.fileversion AS fileversion,
             g.geom AS geom
      FROM   gis_land_geometries g
      JOIN   lands l ON l.id = g.land_id
      LEFT   JOIN file_descriptions fd ON fd.id = l.file_description_id
      WHERE  g.geom && #{bbox_sql} AND l.file_description_id IS NOT NULL
      UNION ALL
      SELECT 'building'::text AS entity_type,
             b.id, b.cadgenno, l.file_description_id,
             fd.validation_status, fd.fileversion,
             g.geom
      FROM   gis_building_geometries g
      JOIN   buildings b ON b.id = g.building_id
      LEFT   JOIN lands l ON l.id = b.land_id
      LEFT   JOIN file_descriptions fd ON fd.id = l.file_description_id
      WHERE  g.geom && #{bbox_sql} AND l.file_description_id IS NOT NULL
    SQL
  end

  def uat_source_sql(bbox_sql)
    <<~SQL
      SELECT u.id AS id,
             u.nat_code AS nat_code,
             u.name AS name,
             u.geom AS geom
      FROM   uat_boundaries u
      WHERE  u.geom IS NOT NULL AND u.geom && #{bbox_sql}
    SQL
  end
end
