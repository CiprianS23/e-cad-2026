class UatBoundariesController < ApplicationController
  # GET /uat_boundaries/geojson?lat=46.77&lng=23.60
  # With lat/lng: returns the single UAT containing that WGS84 point (50m simplification).
  # Without params: returns all 3186 UATs (500m simplification, ~1.6 MB) — kept for fallback.
  def geojson
    if params[:lat].present? && params[:lng].present?
      geojson_for_point(params[:lat].to_f, params[:lng].to_f)
    else
      geojson_all
    end
  end

  private

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
          'geometry',   ST_AsGeoJSON(
                          ST_Transform(
                            ST_SimplifyPreserveTopology(geom, 50),
                            4326
                          ), 6
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
                          ST_Transform(
                            ST_SimplifyPreserveTopology(geom, 500),
                            4326
                          ), 5
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
