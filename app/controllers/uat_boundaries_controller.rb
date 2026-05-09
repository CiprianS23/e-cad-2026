class UatBoundariesController < ApplicationController
  # GET /uat_boundaries/geojson
  # Returns all UAT polygons as GeoJSON in WGS84, with simplified geometry for display.
  def geojson
    # 500m simplification keeps shapes clear at national zoom (7-10).
    # 5 decimal places in coordinates keeps response ~1.6 MB for all 3186 UATs.
    # ST_Transform converts Stereo70 (3844) → WGS84 (4326) for Leaflet.
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
