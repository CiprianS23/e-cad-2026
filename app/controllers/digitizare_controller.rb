class DigitizareController < ApplicationController
  def index; end

  def calculeaza_suprafata
    coords = params[:coords]
    return render json: { suprafata: 0 } if coords.blank? || coords.length < 3

    pts   = coords.map { |c| [c[0].to_f, c[1].to_f] }
    ring  = pts.map { |x, y| "#{x} #{y}" }.join(", ")
    # Închidem inelul dacă nu e deja închis
    ring += ", #{pts.first[0]} #{pts.first[1]}" unless pts.first == pts.last

    wkt = "POLYGON((#{ring}))"

    sql = ActiveRecord::Base.sanitize_sql_array(
      ["SELECT ROUND(ST_Area(ST_SetSRID(ST_GeomFromText(?), 3844))::numeric, 4)", wkt]
    )
    suprafata = ActiveRecord::Base.connection.select_value(sql).to_f

    is_valid  = ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(
        ["SELECT ST_IsValid(ST_SetSRID(ST_GeomFromText(?), 3844))", wkt]
      )
    )
    is_simple = ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(
        ["SELECT ST_IsSimple(ST_SetSRID(ST_GeomFromText(?), 3844))", wkt]
      )
    )

    render json: {
      suprafata:  suprafata,
      is_valid:   is_valid == "t" || is_valid == true,
      is_simple:  is_simple == "t" || is_simple == true
    }
  rescue => e
    render json: { suprafata: 0, error: e.message }, status: :unprocessable_entity
  end

  def locate_parcela
    coords = params[:coords]
    return render json: {} if coords.blank? || coords.length < 3

    pts  = coords.map { |c| [c[0].to_f, c[1].to_f] }
    ring = pts.map { |x, y| "#{x} #{y}" }.join(", ")
    ring += ", #{pts.first[0]} #{pts.first[1]}" unless pts.first == pts.last
    wkt  = "POLYGON((#{ring}))"

    sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL, wkt, wkt])
      SELECT id, numar_cadastral
      FROM parcele_cadastrale
      WHERE geom IS NOT NULL
        AND ST_Intersects(geom, ST_GeomFromText(?, 3844))
      ORDER BY ST_Area(ST_Intersection(geom, ST_GeomFromText(?, 3844))) DESC
      LIMIT 1
    SQL

    result = ActiveRecord::Base.connection.select_one(sql)
    render json: result || {}
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def locate_uat
    coords = params[:coords]
    return render json: {} if coords.blank? || coords.length < 3

    pts  = coords.map { |c| [c[0].to_f, c[1].to_f] }
    ring = pts.map { |x, y| "#{x} #{y}" }.join(", ")
    ring += ", #{pts.first[0]} #{pts.first[1]}" unless pts.first == pts.last
    wkt  = "POLYGON((#{ring}))"

    sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL, wkt])
      WITH poly AS (
        SELECT ST_Centroid(ST_GeomFromText(?, 3844)) AS centroid
      )
      SELECT
        initcap(s.denumire_judet) AS judet,
        initcap(s.denumire_uat)   AS localitate,
        s.tip_uat_abrev
      FROM uat_boundaries u
      JOIN siruta_uats s ON s.cod_siruta = u.nat_code::integer
      CROSS JOIN poly
      ORDER BY
        CASE WHEN ST_Contains(u.geom, poly.centroid) THEN 0 ELSE 1 END,
        ST_Distance(u.geom, poly.centroid)
      LIMIT 1
    SQL

    result = ActiveRecord::Base.connection.select_one(sql)
    render json: result || {}
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def export_dxf
    coords = params[:coords]
    name   = params[:name].presence || "Parcela"
    return head :bad_request if coords.blank? || coords.length < 2

    pts = coords.map { |c| [c[0].to_f, c[1].to_f] }
    send_data build_dxf(pts, name),
      filename:    "#{name.parameterize}_#{Time.current.strftime('%Y%m%d_%H%M%S')}.dxf",
      type:        "application/dxf",
      disposition: "attachment"
  end

  private

  def build_dxf(pts, layer)
    verts = pts.map { |x, y| "10\n#{format('%.4f', x)}\n20\n#{format('%.4f', y)}\n30\n0.0000" }.join("\n")
    <<~DXF
      0
      SECTION
      2
      HEADER
      9
      $ACADVER
      1
      AC1015
      9
      $INSUNITS
      70
      6
      0
      ENDSEC
      0
      SECTION
      2
      TABLES
      0
      TABLE
      2
      LAYER
      70
      1
      0
      LAYER
      2
      #{layer}
      70
      0
      62
      7
      6
      CONTINUOUS
      0
      ENDTABLE
      0
      ENDSEC
      0
      SECTION
      2
      ENTITIES
      0
      LWPOLYLINE
      8
      #{layer}
      90
      #{pts.length}
      70
      1
      #{verts}
      0
      ENDSEC
      0
      EOF
    DXF
  end
end
