class HartaController < ApplicationController
  def index; end

  def cgxml_geojson
    render json: build_cgxml_geojson, content_type: "application/json"
  end

  private

  def build_cgxml_geojson
    sql = <<~SQL
      WITH land_lines AS (
        SELECT land_id,
               ST_MakeLine(coordinates ORDER BY no) AS line
        FROM   points
        WHERE  land_id IS NOT NULL AND coordinates IS NOT NULL
        GROUP  BY land_id
        HAVING COUNT(*) >= 3
      ),
      bld_lines AS (
        SELECT building_id,
               ST_MakeLine(coordinates ORDER BY no) AS line
        FROM   points
        WHERE  building_id IS NOT NULL AND coordinates IS NOT NULL
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
      all_polys AS (
        SELECT * FROM land_polys WHERE ST_IsValid(geom)
        UNION ALL
        SELECT * FROM bld_polys WHERE ST_IsValid(geom)
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
