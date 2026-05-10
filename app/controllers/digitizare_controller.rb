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

    # Toleranțe ZERO pentru snap server-side: clientul OL lucrează nativ în
    # EPSG:3844, coords sunt exacte. Orice ST_Snap > 0 ar masca lipsa unei
    # alinieri reale a vertecșilor → posibili sliveri. Detecția se face la
    # 0.01 mp (= 1 cm²) — sub asta e doar floating-point în PostGIS.
    snap_tol      = 0.0   # m  — fără fuzzy snap, alinierea TREBUIE să vină din client
    overlap_min   = 0.01  # mp — 1 cm², strict
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
    overlap_sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL, wkt, excl, overlap_min])
      WITH np AS (SELECT ST_GeomFromText(?, 3844) AS geom)
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

    # ── Slivers (gap-uri mici) — calcul real al gap area chiar și când
    # poligoanele se ating într-un punct dar au goluri pe muchii.
    # Tehnica: zone aflate ÎN AMBELE buffer-uri (0.5m) DAR neacoperite
    # nici de poligonul curent, nici de vecin = gap real.
    sliver_sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL, wkt, sliver_dist, sliver_max_mp])
      WITH np AS (SELECT ST_GeomFromText(?, 3844) AS geom),
           pairs AS (
             SELECT p.id, p.numar_cadastral AS label, p.geom
             FROM parcele_cadastrale p, np
             WHERE p.geom IS NOT NULL
               AND ST_DWithin(p.geom, np.geom, ?)
               AND NOT ST_Overlaps(p.geom, np.geom)
           ),
           gaps AS (
             SELECT
               pairs.id, pairs.label,
               ST_CollectionExtract(
                 ST_MakeValid(
                   ST_Difference(
                     ST_Intersection(ST_Buffer(np.geom, 0.5), ST_Buffer(pairs.geom, 0.5)),
                     ST_Union(np.geom, pairs.geom)
                   )
                 ),
                 3
               ) AS gap_geom
             FROM pairs, np
           )
      SELECT id AS neighbor_id, label AS neighbor_label,
        ROUND(ST_Area(gap_geom)::numeric, 3) AS gap_area,
        ST_AsGeoJSON(ST_Transform(gap_geom, 4326), 6) AS geojson
      FROM gaps
      WHERE gap_geom IS NOT NULL
        AND NOT ST_IsEmpty(gap_geom)
        AND ST_Area(gap_geom) > 0.01
        AND ST_Area(gap_geom) < ?
    SQL
    ActiveRecord::Base.connection.select_all(sliver_sql).each do |row|
      issues << {
        type: "sliver", severity: "warning", neighbor_kind: "parcela",
        neighbor_id: row["neighbor_id"], neighbor_label: row["neighbor_label"],
        area: row["gap_area"].to_f,
        message: "Gap între tine și parcela #{row['neighbor_label']}: #{row['gap_area']} mp",
        geojson: row["geojson"]
      }
    end

    # ── Vertex-on-vertex (asimetric A→B): vertex NOU pe muchia vecinului, dar NU pe vertex vecin
    vov_sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL, wkt, wkt])
      WITH np AS (SELECT ST_GeomFromText(?, 3844) AS geom),
           new_verts AS (
             SELECT (ST_DumpPoints(ST_GeomFromText(?, 3844))).geom AS pt
           ),
           neighbors AS (
             SELECT p.id, p.numar_cadastral AS label, p.geom
             FROM parcele_cadastrale p, np
             WHERE p.geom IS NOT NULL AND ST_DWithin(p.geom, np.geom, 0.5)
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
        message: "Vertex nou (#{row['x'].to_f.round(2)}, #{row['y'].to_f.round(2)}) pe muchia parcelei #{row['neighbor_label']} fără vertex corespondent",
        geojson: row["geojson"]
      }
    end

    # ── Vertex-on-vertex (asimetric B→A): vertex VECIN pe muchia poligonului nou, dar NU vertex nou
    vov_rev_sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL, wkt, wkt])
      WITH np AS (SELECT ST_GeomFromText(?, 3844) AS geom),
           new_verts AS (
             SELECT (ST_DumpPoints(ST_GeomFromText(?, 3844))).geom AS pt
           ),
           neighbors AS (
             SELECT p.id, p.numar_cadastral AS label, p.geom
             FROM parcele_cadastrale p, np
             WHERE p.geom IS NOT NULL AND ST_DWithin(p.geom, np.geom, 0.5)
           ),
           neighbor_verts AS (
             SELECT n.id AS neighbor_id, n.label AS neighbor_label,
                    (ST_DumpPoints(n.geom)).geom AS pt
             FROM neighbors n
           )
      SELECT nv.neighbor_id, nv.neighbor_label,
        ST_AsGeoJSON(ST_Transform(nv.pt, 4326), 6) AS geojson,
        ST_X(nv.pt) AS x, ST_Y(nv.pt) AS y
      FROM neighbor_verts nv, np
      WHERE ST_DWithin(nv.pt, ST_Boundary(np.geom), 0.05)
        AND NOT EXISTS (
          SELECT 1 FROM new_verts WHERE ST_DWithin(nv.pt, new_verts.pt, 0.05)
        )
    SQL
    ActiveRecord::Base.connection.select_all(vov_rev_sql).each do |row|
      issues << {
        type: "neighbor_vertex_off", severity: "warning", neighbor_kind: "parcela",
        neighbor_id: row["neighbor_id"], neighbor_label: row["neighbor_label"],
        x: row["x"].to_f.round(3), y: row["y"].to_f.round(3),
        message: "Vertex vecin (#{row['x'].to_f.round(2)}, #{row['y'].to_f.round(2)}) al parcelei #{row['neighbor_label']} pe muchia ta — adaugă-l ca vertex (Click pe muchie + drag)",
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

  # Salvare topology-aware: actualizează simultan poligonul primar + vecinii
  # care au fost modificați în edit mode (toate într-o tranzacție).
  def save_batch
    primary   = params[:primary]
    neighbors = params[:neighbors] || []
    return render json: { ok: false, errors: ["primary lipsește"] }, status: :unprocessable_entity if primary.blank?

    errors = []
    redirect_url = nil

    ActiveRecord::Base.transaction do
      saved = update_one(primary, errors)
      raise ActiveRecord::Rollback if errors.any?

      neighbors.each do |n|
        update_one(n, errors)
        raise ActiveRecord::Rollback if errors.any?
      end

      kind = primary[:kind] || primary["kind"]
      id   = primary[:id]   || primary["id"]
      redirect_url = kind == "cladire" ? "/cladiri_cadastrale/#{id}" : "/parcele_cadastrale/#{id}"
    end

    if errors.any?
      render json: { ok: false, errors: errors }, status: :unprocessable_entity
    else
      render json: { ok: true, redirect: redirect_url }
    end
  rescue => e
    render json: { ok: false, errors: ["Eroare server: #{e.message}"] }, status: :unprocessable_entity
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

  # Helper pentru save_batch — actualizează un poligon (parcelă sau clădire)
  # cu noul WKT + suprafață. Adaugă mesajele de eroare la array-ul `errors`.
  def update_one(payload, errors)
    kind = payload[:kind] || payload["kind"]
    id   = payload[:id]   || payload["id"]
    wkt  = payload[:geom_wkt] || payload["geom_wkt"]
    area = payload[:suprafata_mp] || payload["suprafata_mp"]

    klass = kind == "cladire" ? CladireCadastrala : ParcelaCadastrala
    record = klass.find_by(id: id)
    unless record
      errors << "#{kind} ##{id}: nu există"
      return nil
    end
    attrs = { geom_wkt: wkt }
    if area.present?
      attrs[kind == "cladire" ? :suprafata_construita_mp : :suprafata_mp] = area
    end
    unless record.update(attrs)
      label = record.respond_to?(:numar_cadastral) ? record.numar_cadastral : id
      record.errors.full_messages.each { |m| errors << "#{kind} #{label}: #{m}" }
    end
    record
  end

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
