class DigitizareController < ApplicationController
  def verifica_topologie
    coords    = params[:coords]
    exclude_id = params[:exclude_id].presence&.to_i
    entity     = params[:entity_type].presence || "parcela"
    return render json: { issues: [] } if coords.blank? || coords.length < 3

    pts  = coords.map { |c| [c[0].to_f, c[1].to_f] }
    ring = pts.map { |x, y| "#{x} #{y}" }.join(", ")
    ring += ", #{pts.first[0]} #{pts.first[1]}" unless pts.first == pts.last
    wkt  = "POLYGON((#{ring}))"

    # Toleranțe (în metri Stereo70). Clientul lucrează nativ în EPSG:3844,
    # deci nu mai există erori de round-trip prin Web Mercator. Snap rezidual
    # mic doar pentru floating-point noise.
    snap_tol      = 0.05  # m  — 5cm, conform spec snap_tolerance
    overlap_min   = 0.10  # mp — conform spec sliver_threshold
    sliver_max_mp = 1.00  # mp
    sliver_dist   = 1.00  # m

    issues = []

    # ── Suprapuneri (overlap) cu același tip de entitate ──────────────────
    # Aplicăm ST_Snap înainte de check ca să eliminăm false-pozitive cauzate
    # de precizie sub-cm (vertecși snap-uiti pe vecin în client, dar shifți
    # cu cm/dm după conversia 3857 ↔ 3844).
    overlap_target = entity == "cladire" ? ["cladire", "cladiri_cadastrale"] : ["parcela", "parcele_cadastrale"]
    kind, table = overlap_target
    excl = exclude_id || 0
    overlap_sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL, wkt, snap_tol, snap_tol, excl, overlap_min])
      WITH np_orig AS (SELECT ST_GeomFromText(?, 3844) AS geom),
           ref AS (
             SELECT ST_Collect(t.geom) AS geom
             FROM #{table} t, np_orig
             WHERE t.geom IS NOT NULL
               AND ST_DWithin(t.geom, np_orig.geom, ?)
           ),
           np AS (
             SELECT CASE WHEN ref.geom IS NOT NULL
                          THEN ST_MakeValid(ST_Snap(np_orig.geom, ref.geom, ?))
                          ELSE np_orig.geom
                    END AS geom
             FROM np_orig, ref
           )
      SELECT t.id, t.numar_cadastral AS label,
        ST_Area(ST_Intersection(t.geom, np.geom)) AS area,
        ST_AsGeoJSON(ST_Transform(ST_Intersection(t.geom, np.geom), 4326), 6) AS geojson
      FROM #{table} t, np
      WHERE t.geom IS NOT NULL
        AND t.id != ?
        AND ST_Intersects(t.geom, np.geom)
        AND ST_Area(ST_Intersection(t.geom, np.geom)) > ?
    SQL
    ActiveRecord::Base.connection.select_all(overlap_sql).each do |row|
      issues << {
        type: "overlap", severity: "error", neighbor_kind: kind,
        neighbor_id: row["id"], neighbor_label: row["label"],
        area: row["area"].to_f.round(3),
        message: "Suprapunere cu #{kind} #{row['label']}: #{row['area'].to_f.round(2)} mp",
        geojson: row["geojson"]
      }
    end

    # ── Slivers (gap-uri mici) — vecini la distanță < sliver_dist dar NEadiacenți
    sliver_sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL, wkt, sliver_dist])
      WITH np AS (SELECT ST_GeomFromText(?, 3844) AS geom)
      SELECT 'parcela' AS kind, p.id, p.numar_cadastral AS label,
        ST_AsGeoJSON(ST_Transform(p.geom, 4326), 6) AS geojson,
        ST_Distance(p.geom, np.geom) AS dist
      FROM parcele_cadastrale p, np
      WHERE p.geom IS NOT NULL
        AND ST_DWithin(p.geom, np.geom, ?)
        AND NOT ST_Touches(p.geom, np.geom)
        AND NOT ST_Intersects(p.geom, np.geom)
    SQL
    ActiveRecord::Base.connection.select_all(sliver_sql).each do |row|
      issues << {
        type: "sliver", severity: "warning", neighbor_kind: row["kind"],
        neighbor_id: row["id"], neighbor_label: row["label"],
        dist: row["dist"].to_f.round(3),
        message: "Sliver: #{row['kind']} #{row['label']} la #{row['dist'].to_f.round(2)} m (gap < 1 mp posibil)",
        geojson: row["geojson"]
      }
    end

    # ── Vertex-on-vertex — vertex nou aflat pe muchia unui vecin, dar NU pe un vertex al vecinului
    vov_sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL, wkt, wkt])
      WITH np AS (SELECT ST_GeomFromText(?, 3844) AS geom),
           new_verts AS (
             SELECT (ST_DumpPoints(ST_GeomFromText(?, 3844))).geom AS pt
           ),
           neighbors AS (
             SELECT p.id, p.numar_cadastral AS label, p.geom
             FROM parcele_cadastrale p, np
             WHERE p.geom IS NOT NULL AND ST_Touches(p.geom, np.geom)
           )
      SELECT n.id AS neighbor_id, n.label AS neighbor_label,
        ST_AsGeoJSON(ST_Transform(v.pt, 4326), 6) AS geojson,
        ST_X(v.pt) AS x, ST_Y(v.pt) AS y
      FROM new_verts v, neighbors n
      WHERE ST_DWithin(v.pt, ST_Boundary(n.geom), 0.05)
        AND NOT EXISTS (
          SELECT 1 FROM (SELECT (ST_DumpPoints(n.geom)).geom AS np_pt) AS d
          WHERE ST_DWithin(v.pt, d.np_pt, 0.05)
        )
    SQL
    ActiveRecord::Base.connection.select_all(vov_sql).each do |row|
      issues << {
        type: "vertex_off", severity: "warning", neighbor_kind: "parcela",
        neighbor_id: row["neighbor_id"], neighbor_label: row["neighbor_label"],
        x: row["x"].to_f.round(3), y: row["y"].to_f.round(3),
        message: "Vertex (#{row['x'].to_f.round(2)}, #{row['y'].to_f.round(2)}) pe muchia parcelei #{row['neighbor_label']} fără vertex corespondent",
        geojson: row["geojson"]
      }
    end

    # ── Clădire în parcele diferite (vertecșii nu trebuie să traverseze graniță parcelă)
    if entity == "cladire"
      cross_sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL, wkt])
        WITH np AS (SELECT ST_GeomFromText(?, 3844) AS geom),
             vts AS (SELECT (ST_DumpPoints(np.geom)).geom AS pt FROM np)
        SELECT DISTINCT p.id, p.numar_cadastral AS label,
          ST_AsGeoJSON(ST_Transform(p.geom, 4326), 6) AS geojson
        FROM parcele_cadastrale p, vts
        WHERE p.geom IS NOT NULL
          AND ST_Intersects(p.geom, vts.pt)
      SQL
      parcele_atinse = ActiveRecord::Base.connection.select_all(cross_sql).to_a
      if parcele_atinse.size > 1
        labels = parcele_atinse.map { |r| r["label"] }.join(", ")
        # Adaugă eroare globală + evidențiere pe fiecare parcelă atinsă
        issues << {
          type: "cladire_multi_parcela", severity: "error", neighbor_kind: "parcela",
          message: "Clădirea are vertecși în #{parcele_atinse.size} parcele diferite (#{labels}) — trebuie încadrată într-o singură parcelă",
          geojson: nil
        }
        parcele_atinse.each do |p|
          issues << {
            type: "cladire_multi_parcela_neighbor", severity: "error", neighbor_kind: "parcela",
            neighbor_id: p["id"], neighbor_label: p["label"],
            message: "Parcela #{p['label']} (clădirea o traversează)",
            geojson: p["geojson"]
          }
        end
      end
    end

    has_errors = issues.any? { |i| i[:severity] == "error" }
    render json: { issues: issues, has_errors: has_errors }
  rescue => e
    render json: { issues: [], error: e.message }, status: :unprocessable_entity
  end

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
