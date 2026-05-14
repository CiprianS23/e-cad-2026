class UatBoundariesController < ApplicationController
  # GET /uat_boundaries/geojson
  #   (default)        → DOAR UAT-urile care conțin parcele sau clădiri reale
  #   ?lat=&lng=       → UAT-ul care conține punctul WGS84
  #   ?all=1           → toate UAT-urile (~1.6 MB, fallback)
  def geojson
    if params[:all].present?
      geojson_all
    elsif params[:lat].present? && params[:lng].present?
      geojson_for_point(params[:lat].to_f, params[:lng].to_f)
    else
      geojson_for_geometries
    end
  end

  private

  # Returnează DOAR UAT-urile care intersectează cel puțin o parcelă sau
  # clădire din DB — adică UAT-urile relevante pentru datele utilizatorului.
  def geojson_for_geometries
    sql = <<~SQL
      SELECT json_build_object(
        'type', 'FeatureCollection',
        'features', COALESCE(json_agg(feat), '[]'::json)
      )
      FROM (
        SELECT json_build_object(
          'type',       'Feature',
          'id',         u.id,
          'geometry',   ST_AsGeoJSON(u.geom, 4)::json,
          'properties', json_build_object(
            'id',           u.id,
            'nat_code',     u.nat_code,
            'name',         u.name,
            'nat_lev_name', u.nat_lev_name,
            'shape_area',   u.shape_area
          )
        ) AS feat
        FROM uat_boundaries u
        WHERE u.geom IS NOT NULL
          AND (
            EXISTS (SELECT 1 FROM gis_land_geometries g
                    WHERE ST_Intersects(u.geom, g.geom))
            OR EXISTS (SELECT 1 FROM gis_building_geometries g
                       WHERE ST_Intersects(u.geom, g.geom))
            OR EXISTS (SELECT 1 FROM points p
                       WHERE p.coordinates IS NOT NULL AND ST_Intersects(u.geom, p.coordinates))
          )
      ) subq
    SQL

    result = ActiveRecord::Base.connection.select_value(sql)
    render json: result, content_type: "application/geo+json"
  end

  def geojson_for_point(lat, lng)
    sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL, lng, lat])
      SELECT json_build_object(
        'type', 'FeatureCollection',
        'features', COALESCE(json_agg(feat), '[]'::json)
      )
      FROM (
        SELECT json_build_object(
          'type',       'Feature',
          'id',         id,
          'geometry',   ST_AsGeoJSON(geom, 4)::json,
          'properties', json_build_object(
            'id',           id,
            'nat_code',     nat_code,
            'name',         name,
            'nat_lev_name', nat_lev_name,
            'shape_area',   shape_area
          )
        ) AS feat
        FROM uat_boundaries
        WHERE geom IS NOT NULL
          AND ST_Contains(
                geom,
                ST_Transform(ST_SetSRID(ST_Point(?, ?), 4326), 3844)
              )
      ) subq
    SQL

    result = ActiveRecord::Base.connection.select_value(sql)
    render json: result, content_type: "application/geo+json"
  end

  def geojson_all
    sql = <<~SQL
      SELECT json_build_object(
        'type', 'FeatureCollection',
        'features', COALESCE(json_agg(feat), '[]'::json)
      )
      FROM (
        SELECT json_build_object(
          'type',       'Feature',
          'id',         id,
          'geometry',   ST_AsGeoJSON(
                          ST_SimplifyPreserveTopology(geom, 500), 2
                        )::json,
          'properties', json_build_object(
            'id',           id,
            'nat_code',     nat_code,
            'name',         name,
            'nat_lev_name', nat_lev_name,
            'shape_area',   shape_area
          )
        ) AS feat
        FROM uat_boundaries
        WHERE geom IS NOT NULL
      ) subq
    SQL

    result = ActiveRecord::Base.connection.select_value(sql)
    render json: result, content_type: "application/geo+json"
  end
end
