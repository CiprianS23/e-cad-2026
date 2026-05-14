class HartaController < ApplicationController
  # Buffer (metri) aplicat în jurul limitei UAT pentru a permite digitizare la
  # marginea hartei fără ca tile-urile vecine să cadă în afara extent-ului.
  BASE_LAYER_BUFFER_M = 200

  # UAT curent pentru dev (mediul izolat GIS) — Sascut.
  # În producție va veni din scope-ul utilizatorului / comuna_id.
  DEV_UAT_NAT_CODE = "25068".freeze

  def index
    @base_extent = base_extent_for_uat(DEV_UAT_NAT_CODE, BASE_LAYER_BUFFER_M)
  end

  def cgxml_geojson
    render json: build_cgxml_geojson, content_type: "application/json"
  end

  private

  # Bbox (în EPSG:3844) al UAT identificat prin nat_code, extins cu `buffer_m`
  # metri. Folosit ca extent pentru View și layer-ele raster de bază — OL nu
  # mai cere tile-uri în afara zonei, reducând traficul de rețea.
  def base_extent_for_uat(nat_code, buffer_m)
    sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL, buffer_m, nat_code])
      SELECT ST_XMin(b) AS minx, ST_YMin(b) AS miny,
             ST_XMax(b) AS maxx, ST_YMax(b) AS maxy
      FROM (
        SELECT ST_Envelope(ST_Buffer(geom, ?)) AS b
        FROM uat_boundaries
        WHERE nat_code = ? AND geom IS NOT NULL
        LIMIT 1
      ) sub
    SQL
    row = ActiveRecord::Base.connection.select_one(sql)
    return nil unless row && row["minx"]
    [row["minx"].to_f, row["miny"].to_f, row["maxx"].to_f, row["maxy"].to_f]
  end

  def build_cgxml_geojson
    # Geometria provine din două surse:
    #   (a) `gis_land_geometries` / `gis_building_geometries` — cache rapid pentru
    #       drafturi digitizate ȘI pentru lands cgxml „fittate" (când e disponibil)
    #   (b) reconstrucție din `points` — pentru lands cgxml fără cache
    # Prioritizăm (a) când există: imobilul nou-digitizat e cel curent, nu vechiul.
    sql = <<~SQL
      WITH land_lines AS (
        SELECT land_id,
               ST_MakeLine(coordinates ORDER BY no) AS line
        FROM   points
        WHERE  land_id IS NOT NULL AND coordinates IS NOT NULL
          AND  NOT EXISTS (SELECT 1 FROM gis_land_geometries g WHERE g.land_id = points.land_id)
        GROUP  BY land_id
        HAVING COUNT(*) >= 3
      ),
      bld_lines AS (
        SELECT building_id,
               ST_MakeLine(coordinates ORDER BY no) AS line
        FROM   points
        WHERE  building_id IS NOT NULL AND coordinates IS NOT NULL
          AND  NOT EXISTS (SELECT 1 FROM gis_building_geometries g WHERE g.building_id = points.building_id)
        GROUP  BY building_id
        HAVING COUNT(*) >= 3
      ),
      land_polys AS (
        SELECT 'land'::text                      AS entity_type,
               l.id,
               l.file_description_id,
               l.measuredarea,
               l.parcellegalarea,
               l.cadgenno,
               l.e2identifier,
               l.cadsector,
               l.isnew,
               NULL::integer                     AS buildno,
               NULL::text                        AS buildingdestination,
               NULL::integer                     AS levelsno,
               NULL::text                        AS notes,
               fd.filename,
               fd.fileversion,
               fd.operationtype,
               fd.validation_status,
               fd.validation_errors_count,
               fd.validation_warnings_count,
               CASE WHEN ST_IsClosed(ll.line)
                    THEN ST_MakePolygon(ll.line)
                    ELSE ST_MakePolygon(ST_AddPoint(ll.line, ST_StartPoint(ll.line)))
               END AS geom
        FROM   land_lines ll
        JOIN   lands l ON l.id = ll.land_id
        LEFT   JOIN file_descriptions fd ON fd.id = l.file_description_id
      ),
      land_polys_cache AS (
        SELECT 'land'::text                      AS entity_type,
               l.id,
               l.file_description_id,
               l.measuredarea,
               l.parcellegalarea,
               l.cadgenno,
               l.e2identifier,
               l.cadsector,
               l.isnew,
               NULL::integer                     AS buildno,
               NULL::text                        AS buildingdestination,
               NULL::integer                     AS levelsno,
               g.status                          AS notes,
               fd.filename,
               fd.fileversion,
               fd.operationtype,
               fd.validation_status,
               fd.validation_errors_count,
               fd.validation_warnings_count,
               g.geom                            AS geom
        FROM   gis_land_geometries g
        JOIN   lands l ON l.id = g.land_id
        LEFT   JOIN file_descriptions fd ON fd.id = l.file_description_id
      ),
      bld_polys AS (
        SELECT 'building'::text                  AS entity_type,
               b.id,
               l.file_description_id,
               b.measuredarea,
               b.legalarea                       AS parcellegalarea,
               b.cadgenno,
               b.e2identifier,
               NULL::text                        AS cadsector,
               NULL::boolean                     AS isnew,
               b.buildno,
               b.buildingdestination,
               b.levelsno,
               b.notes,
               fd.filename,
               fd.fileversion,
               fd.operationtype,
               fd.validation_status,
               fd.validation_errors_count,
               fd.validation_warnings_count,
               CASE WHEN ST_IsClosed(bl.line)
                    THEN ST_MakePolygon(bl.line)
                    ELSE ST_MakePolygon(ST_AddPoint(bl.line, ST_StartPoint(bl.line)))
               END AS geom
        FROM   bld_lines bl
        JOIN   buildings b ON b.id = bl.building_id
        JOIN   lands l ON l.id = b.land_id
        LEFT   JOIN file_descriptions fd ON fd.id = l.file_description_id
      ),
      bld_polys_cache AS (
        SELECT 'building'::text                  AS entity_type,
               b.id,
               l.file_description_id,
               b.measuredarea,
               b.legalarea                       AS parcellegalarea,
               b.cadgenno,
               b.e2identifier,
               NULL::text                        AS cadsector,
               NULL::boolean                     AS isnew,
               b.buildno,
               b.buildingdestination,
               b.levelsno,
               g.status                          AS notes,
               fd.filename,
               fd.fileversion,
               fd.operationtype,
               fd.validation_status,
               fd.validation_errors_count,
               fd.validation_warnings_count,
               g.geom                            AS geom
        FROM   gis_building_geometries g
        JOIN   buildings b ON b.id = g.building_id
        LEFT   JOIN lands l ON l.id = b.land_id
        LEFT   JOIN file_descriptions fd ON fd.id = l.file_description_id
      ),
      all_polys AS (
        SELECT * FROM land_polys_cache WHERE ST_IsValid(geom)
        UNION ALL
        SELECT * FROM land_polys       WHERE ST_IsValid(geom)
        UNION ALL
        SELECT * FROM bld_polys_cache  WHERE ST_IsValid(geom)
        UNION ALL
        SELECT * FROM bld_polys        WHERE ST_IsValid(geom)
      )
      SELECT json_build_object(
        'type', 'FeatureCollection',
        'features', COALESCE(json_agg(
          json_build_object(
            'type',       'Feature',
            'geometry',   ST_AsGeoJSON(ap.geom, 6)::json,
            'properties', json_build_object(
              'entity_type',              ap.entity_type,
              'id',                       ap.id,
              'file_description_id',      ap.file_description_id,
              'measuredarea',             ap.measuredarea,
              'parcellegalarea',          ap.parcellegalarea,
              'cadgenno',                 ap.cadgenno,
              'e2identifier',             ap.e2identifier,
              'cadsector',                ap.cadsector,
              'isnew',                    ap.isnew,
              'buildno',                  ap.buildno,
              'buildingdestination',      ap.buildingdestination,
              'levelsno',                 ap.levelsno,
              'notes',                    ap.notes,
              'filename',                 ap.filename,
              'fileversion',              ap.fileversion,
              'operationtype',            ap.operationtype,
              'validation_status',        ap.validation_status,
              'validation_errors_count',  ap.validation_errors_count,
              'validation_warnings_count',ap.validation_warnings_count
            )
          )
        ), '[]'::json)
      )
      FROM all_polys ap
    SQL

    ActiveRecord::Base.connection.select_value(sql)
  end
end
