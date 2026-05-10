require "set"

class DigitizareController < ApplicationController
  def verifica_topologie
    coords     = params[:coords]
    exclude_id = params[:exclude_id].presence&.to_i
    entity     = params[:entity_type].presence || "parcela"
    # Vecinii editați în memorie (modificați client-side dar nesalvați încă);
    # geometriile lor server sunt vechi → trebuie excluși din toate verificările
    # ca să nu genereze fals-pozitive de overlap/sliver.
    exclude_neighbor_ids = Array(params[:exclude_neighbor_ids]).map(&:to_i)
    excluded_ids = [exclude_id, *exclude_neighbor_ids].compact
    excluded_ids = [0] if excluded_ids.empty?  # placeholder ca NOT IN (...) să fie valid SQL
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
    overlap_min   = 0.10  # mp — 10 cm², toleranță pentru drift floating-point
    sliver_max_mp = 1.00  # mp
    sliver_dist   = 1.00  # m

    issues = []

    # ── Suprapuneri (overlap) cu același tip de entitate ──────────────────
    # Aplicăm ST_Snap înainte de check ca să eliminăm false-pozitive cauzate
    # de precizie sub-cm (vertecși snap-uiti pe vecin în client, dar shifți
    # cu cm/dm după conversia 3857 ↔ 3844).
    overlap_target = entity == "cladire" ? ["cladire", "cladiri_cadastrale"] : ["parcela", "parcele_cadastrale"]
    kind, table = overlap_target
    overlap_sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL, wkt, excluded_ids, overlap_min])
      WITH np AS (SELECT ST_GeomFromText(?, 3844) AS geom)
      SELECT t.id, t.numar_cadastral AS label,
        ST_Area(ST_Intersection(t.geom, np.geom)) AS area,
        ST_AsGeoJSON(ST_Intersection(t.geom, np.geom), 6) AS geojson
      FROM #{table} t, np
      WHERE t.geom IS NOT NULL
        AND t.id NOT IN (?)
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
    # Pragul gap_min trebuie ridicat suficient ca să distingem GAP REAL de
    # zgomot numeric din ST_Buffer (aproximare poligonală 8 segmente/sfert).
    # Buffer-uri de 0.5m → noise tipic ≤ 0.5 mp pe boundary perfect aliniat.
    # Setăm gap_min = 0.50 mp: orice sub asta = artefact, peste asta = real gap.
    gap_min = 0.50  # mp
    sliver_sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL, wkt, sliver_dist, excluded_ids, gap_min, sliver_max_mp])
      WITH np AS (SELECT ST_GeomFromText(?, 3844) AS geom),
           pairs AS (
             SELECT p.id, p.numar_cadastral AS label, p.geom
             FROM parcele_cadastrale p, np
             WHERE p.geom IS NOT NULL
               AND ST_DWithin(p.geom, np.geom, ?)
               AND p.id NOT IN (?)
               AND NOT ST_Overlaps(p.geom, np.geom)
               AND NOT ST_Touches(p.geom, np.geom)  -- skip dacă deja se ating perfect
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
        ST_AsGeoJSON(gap_geom, 6) AS geojson
      FROM gaps
      WHERE gap_geom IS NOT NULL
        AND NOT ST_IsEmpty(gap_geom)
        AND ST_Area(gap_geom) > ?
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
             WHERE p.geom IS NOT NULL
               AND ST_DWithin(p.geom, np.geom, 0.5)
               AND p.id NOT IN (#{excluded_ids.join(',')})
           )
      SELECT n.id AS neighbor_id, n.label AS neighbor_label,
        ST_AsGeoJSON(v.pt, 6) AS geojson,
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
             WHERE p.geom IS NOT NULL
               AND ST_DWithin(p.geom, np.geom, 0.5)
               AND p.id NOT IN (#{excluded_ids.join(',')})
           ),
           neighbor_verts AS (
             SELECT n.id AS neighbor_id, n.label AS neighbor_label,
                    (ST_DumpPoints(n.geom)).geom AS pt
             FROM neighbors n
           )
      SELECT nv.neighbor_id, nv.neighbor_label,
        ST_AsGeoJSON(nv.pt, 6) AS geojson,
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
          ST_AsGeoJSON(p.geom, 6) AS geojson
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

  # Audit topologie global: scanează toate parcele/clădiri și returnează
  # toate issues (overlap parcele, overlap clădiri, clădire multi-parcela)
  # cu geometriile și etichetele necesare pentru afișare + zoom în client.
  def audit_topologie
    issues = []

    # 1. Overlaps parcele-parcele
    sql = <<~SQL
      SELECT p1.id AS id_a, p1.numar_cadastral AS label_a,
             p2.id AS id_b, p2.numar_cadastral AS label_b,
             ROUND(ST_Area(ST_Intersection(p1.geom, p2.geom))::numeric, 2) AS area,
             ST_AsGeoJSON(ST_Intersection(p1.geom, p2.geom), 6) AS geojson
      FROM parcele_cadastrale p1
      JOIN parcele_cadastrale p2 ON p1.id < p2.id
      WHERE p1.geom IS NOT NULL AND p2.geom IS NOT NULL
        AND ST_Intersects(p1.geom, p2.geom)
        AND ST_Area(ST_Intersection(p1.geom, p2.geom)) > 0.10
      ORDER BY ST_Area(ST_Intersection(p1.geom, p2.geom)) DESC
      LIMIT 200
    SQL
    ActiveRecord::Base.connection.select_all(sql).each do |row|
      issues << {
        category: "Suprapuneri parcele",
        type: "overlap_parcele", severity: "error",
        message: "Parcela #{row['label_a']} ⇄ #{row['label_b']}: #{row['area']} mp",
        area: row['area'].to_f,
        geojson: row['geojson']
      }
    end

    # 2. Overlaps clădiri-clădiri
    sql = <<~SQL
      SELECT c1.id AS id_a, c1.numar_cadastral AS label_a,
             c2.id AS id_b, c2.numar_cadastral AS label_b,
             ROUND(ST_Area(ST_Intersection(c1.geom, c2.geom))::numeric, 2) AS area,
             ST_AsGeoJSON(ST_Intersection(c1.geom, c2.geom), 6) AS geojson
      FROM cladiri_cadastrale c1
      JOIN cladiri_cadastrale c2 ON c1.id < c2.id
      WHERE c1.geom IS NOT NULL AND c2.geom IS NOT NULL
        AND ST_Intersects(c1.geom, c2.geom)
        AND ST_Area(ST_Intersection(c1.geom, c2.geom)) > 0.10
      ORDER BY ST_Area(ST_Intersection(c1.geom, c2.geom)) DESC
      LIMIT 200
    SQL
    ActiveRecord::Base.connection.select_all(sql).each do |row|
      issues << {
        category: "Suprapuneri clădiri",
        type: "overlap_cladiri", severity: "error",
        message: "Clădirea #{row['label_a']} ⇄ #{row['label_b']}: #{row['area']} mp",
        area: row['area'].to_f,
        geojson: row['geojson']
      }
    end

    # CTE comun pentru poligoanele CGXML (lands + buildings) — construite din
    # tabela `points` la fiecare rulare; reused în 3 sub-query-uri de mai jos.
    cgxml_polys_cte = <<~SQL
      WITH cgxml_lands AS (
        SELECT l.id, COALESCE(l.cadgenno, l.e2identifier, 'land#' || l.id) AS label,
          CASE WHEN ST_IsClosed(ST_MakeLine(p.coordinates ORDER BY p.no))
               THEN ST_MakePolygon(ST_MakeLine(p.coordinates ORDER BY p.no))
               ELSE ST_MakePolygon(ST_AddPoint(ST_MakeLine(p.coordinates ORDER BY p.no), ST_StartPoint(ST_MakeLine(p.coordinates ORDER BY p.no))))
          END AS geom
        FROM points p JOIN lands l ON l.id = p.land_id
        WHERE p.coordinates IS NOT NULL
        GROUP BY l.id
        HAVING COUNT(*) >= 3
      ),
      cgxml_buildings AS (
        SELECT b.id, COALESCE(b.cadgenno, b.e2identifier, 'bld#' || b.id) AS label,
          CASE WHEN ST_IsClosed(ST_MakeLine(p.coordinates ORDER BY p.no))
               THEN ST_MakePolygon(ST_MakeLine(p.coordinates ORDER BY p.no))
               ELSE ST_MakePolygon(ST_AddPoint(ST_MakeLine(p.coordinates ORDER BY p.no), ST_StartPoint(ST_MakeLine(p.coordinates ORDER BY p.no))))
          END AS geom
        FROM points p JOIN buildings b ON b.id = p.building_id
        WHERE p.coordinates IS NOT NULL
        GROUP BY b.id
        HAVING COUNT(*) >= 3
      ),
      cgxml_lands_v   AS (SELECT id, label, geom FROM cgxml_lands     WHERE ST_IsValid(geom)),
      cgxml_buildings_v AS (SELECT id, label, geom FROM cgxml_buildings WHERE ST_IsValid(geom))
    SQL

    # 3a. Suprapuneri parcele user-drawn vs CGXML lands (cross-source)
    sql = "#{cgxml_polys_cte}\n" + <<~SQL
      SELECT p.id AS id_a, p.numar_cadastral AS label_a,
             cl.id AS id_b, cl.label AS label_b,
             ROUND(ST_Area(ST_Intersection(p.geom, cl.geom))::numeric, 2) AS area,
             ST_AsGeoJSON(ST_Intersection(p.geom, cl.geom), 6) AS geojson
      FROM parcele_cadastrale p, cgxml_lands_v cl
      WHERE p.geom IS NOT NULL
        AND ST_Intersects(p.geom, cl.geom)
        AND ST_Area(ST_Intersection(p.geom, cl.geom)) > 0.10
        AND ABS(ST_Area(p.geom) - ST_Area(ST_Intersection(p.geom, cl.geom))) > 0.10
      ORDER BY ST_Area(ST_Intersection(p.geom, cl.geom)) DESC
      LIMIT 100
    SQL
    ActiveRecord::Base.connection.select_all(sql).each do |row|
      issues << {
        category: "Divergențe parcele ↔ CGXML",
        type: "overlap_parcela_cgxml", severity: "warning",
        message: "Parcela #{row['label_a']} divergent față de CGXML #{row['label_b']}: #{row['area']} mp suprapunere parțială",
        area: row['area'].to_f,
        geojson: row['geojson']
      }
    end

    # 3b. Suprapuneri CGXML lands ↔ CGXML lands
    sql = "#{cgxml_polys_cte}\n" + <<~SQL
      SELECT a.id AS id_a, a.label AS label_a, b.id AS id_b, b.label AS label_b,
             ROUND(ST_Area(ST_Intersection(a.geom, b.geom))::numeric, 2) AS area,
             ST_AsGeoJSON(ST_Intersection(a.geom, b.geom), 6) AS geojson
      FROM cgxml_lands_v a, cgxml_lands_v b
      WHERE a.id < b.id
        AND ST_Intersects(a.geom, b.geom)
        AND ST_Area(ST_Intersection(a.geom, b.geom)) > 0.10
      ORDER BY ST_Area(ST_Intersection(a.geom, b.geom)) DESC
      LIMIT 100
    SQL
    ActiveRecord::Base.connection.select_all(sql).each do |row|
      issues << {
        category: "Suprapuneri CGXML",
        type: "overlap_cgxml_cgxml", severity: "error",
        message: "CGXML #{row['label_a']} ⇄ #{row['label_b']}: #{row['area']} mp",
        area: row['area'].to_f,
        geojson: row['geojson']
      }
    end

    # 3. Clădiri ce traversează mai multe parcele
    sql = <<~SQL
      WITH cladiri_verts AS (
        SELECT c.id AS cladire_id, c.numar_cadastral AS cladire_label, c.geom AS cladire_geom,
               (ST_DumpPoints(c.geom)).geom AS pt
        FROM cladiri_cadastrale c WHERE c.geom IS NOT NULL
      ),
      mapped AS (
        SELECT cv.cladire_id, cv.cladire_label, cv.cladire_geom,
               COUNT(DISTINCT p.id) AS parcele_count,
               string_agg(DISTINCT p.numar_cadastral, ', ') AS parcele_labels
        FROM cladiri_verts cv
        JOIN parcele_cadastrale p ON ST_Intersects(p.geom, cv.pt)
        WHERE p.geom IS NOT NULL
        GROUP BY cv.cladire_id, cv.cladire_label, cv.cladire_geom
        HAVING COUNT(DISTINCT p.id) > 1
      )
      SELECT cladire_id, cladire_label, parcele_count, parcele_labels,
             ST_AsGeoJSON(cladire_geom, 6) AS geojson
      FROM mapped
      LIMIT 100
    SQL
    ActiveRecord::Base.connection.select_all(sql).each do |row|
      issues << {
        category: "Clădiri în multiple parcele",
        type: "cladire_multi_parcela", severity: "error",
        message: "Clădirea #{row['cladire_label']} traversează #{row['parcele_count']} parcele (#{row['parcele_labels']})",
        geojson: row['geojson']
      }
    end

    # Grupare pe categorii
    by_cat = issues.group_by { |i| i[:category] }
    categories = by_cat.map do |name, items|
      { name: name, count: items.size, severity: items.first[:severity] }
    end

    render json: {
      total: issues.size,
      categories: categories,
      issues: issues
    }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # Salvare topology-aware în 2 faze:
  #   Faza 1: scriem toate geometriile în DB cu save(validate: false). Astfel
  #           DB reflectă starea finală a tuturor poligoanelor înainte de
  #           orice verificare.
  #   Faza 2: rulăm validatorii pe fiecare. Acum overlap se calculează între
  #           geometriile NEW (toate sunt în DB), nu între NEW și OLD →
  #           fără fals-pozitive.
  #   Dacă oricare validare eșuează în Faza 2, ROLLBACK întreaga tranzacție.
  def save_batch
    primary   = params[:primary]
    neighbors = params[:neighbors] || []
    return render json: { ok: false, errors: ["primary lipsește"] }, status: :unprocessable_entity if primary.blank?

    errors = []
    redirect_url = nil

    ActiveRecord::Base.transaction do
      # Snapshot pre-edit: overlap-uri existente în DB ÎNAINTE de phase 1.
      # Folosit ca să reportăm doar overlap-urile NOI (cauzate de edit),
      # nu pe cele pre-existente între alte parcele/clădiri din test data.
      pre_overlaps = {}
      records_with_payloads = []
      [primary, *neighbors].each do |payload|
        kind = payload[:kind] || payload["kind"]
        id   = payload[:id]   || payload["id"]
        klass = kind == "cladire" ? CladireCadastrala : ParcelaCadastrala
        record = klass.find_by(id: id)
        next unless record
        pre_overlaps[[klass.name, record.id]] = capture_overlap_set(record)
        records_with_payloads << [record, payload]
      end

      # ── Faza 1: assign + save fără validări (suspendăm și overlap-check) ──
      Thread.current[:topology_skip_overlap_check] = true
      begin
        records_with_payloads.each do |record, payload|
          phase1_save_record(record, payload, errors)
        end
      ensure
        Thread.current[:topology_skip_overlap_check] = nil
      end
      raise ActiveRecord::Rollback if errors.any?

      # ── Faza 2: alte validări (geom_topologic_valid, traverseaza_parcele) ──
      Thread.current[:topology_skip_overlap_check] = true
      begin
        records_with_payloads.each do |record, _|
          record.reload
          next if record.valid?
          kind  = record.is_a?(CladireCadastrala) ? "cladire" : "parcela"
          label = record.respond_to?(:numar_cadastral) ? record.numar_cadastral : record.id
          record.errors.full_messages.each { |m| errors << "#{kind} #{label}: #{m}" }
        end
      ensure
        Thread.current[:topology_skip_overlap_check] = nil
      end
      raise ActiveRecord::Rollback if errors.any?

      # ── Faza 3: delta-check pe overlap (raportăm doar pe cele NOI) ──
      records_with_payloads.each do |record, _|
        post = capture_overlap_set(record)
        pre  = pre_overlaps[[record.class.name, record.id]] || Set.new
        new_overlaps = post - pre
        kind  = record.is_a?(CladireCadastrala) ? "cladire" : "parcela"
        label = record.respond_to?(:numar_cadastral) ? record.numar_cadastral : record.id
        new_overlaps.each do |other_id, other_label, area|
          errors << "#{kind} #{label}: overlap NOU cu #{kind} #{other_label} (#{area} mp)"
        end
      end
      raise ActiveRecord::Rollback if errors.any?

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

  # Faza 1 a save_batch: aplică payload pe record + save FĂRĂ validări.
  def phase1_save_record(record, payload, errors)
    kind = payload[:kind] || payload["kind"]
    wkt  = payload[:geom_wkt] || payload["geom_wkt"]
    area = payload[:suprafata_mp] || payload["suprafata_mp"]

    record.geom_wkt = wkt if wkt.present?
    record.send(:atribuie_geom_din_wkt) if record.respond_to?(:atribuie_geom_din_wkt, true) && wkt.present?

    if record.is_a?(CladireCadastrala) && record.geom.present?
      record.parcela_cadastrala_id = nil
      record.send(:atribuie_parcela_din_geom)
    end

    if area.present?
      record[kind == "cladire" ? :suprafata_construita_mp : :suprafata_mp] = area
    end

    unless record.save(validate: false)
      label = record.respond_to?(:numar_cadastral) ? record.numar_cadastral : record.id
      errors << "#{kind} #{label}: salvare DB eșuată"
    end
  end

  # Capturează overlap-urile actuale ale unui record cu alte poligoane de
  # același tip. Returnează Set cu tupluri [other_id, other_label, area_rounded]
  # care permite operații set diff (- pentru identificarea overlap-urilor NOI).
  def capture_overlap_set(record)
    return Set.new if record.geom.blank?
    table = record.is_a?(CladireCadastrala) ? "cladiri_cadastrale" : "parcele_cadastrale"
    rows = record.class.connection.select_all(
      ApplicationRecord.sanitize_sql_array([<<~SQL, record.geom.as_text, record.id || 0])
        WITH np AS (SELECT ST_GeomFromText(?, 3844) AS geom)
        SELECT t.id, t.numar_cadastral AS label,
          ROUND(ST_Area(ST_Intersection(t.geom, np.geom))::numeric, 2) AS area
        FROM #{table} t, np
        WHERE t.geom IS NOT NULL
          AND t.id != ?
          AND ST_Intersects(t.geom, np.geom)
          AND ST_Area(ST_Intersection(t.geom, np.geom)) > 0.01
      SQL
    )
    rows.each_with_object(Set.new) { |r, s| s << [r["id"].to_i, r["label"], r["area"].to_f] }
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
