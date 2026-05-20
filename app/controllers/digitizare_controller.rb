require "set"
require "shellwords"
require "tmpdir"
require "json"

# Digitizare interactivă pe hartă. Scrie direct în `lands`+`gis_land_geometries`
# și `buildings`+`gis_building_geometries` (drafturi pre-juridice), nu în tabele
# paralele. Lands fără registrations = draft (echivalentul vechi „parcela_cadastrala");
# Lands cu registrations = imobil juridic complet.
class DigitizareController < ApplicationController
  DRAFT_PREFIX = "DR".freeze

  # ── Verificări de topologie pe geometria propusă (fără DB write) ──────
  def verifica_topologie
    coords     = params[:coords]
    exclude_id = params[:exclude_id].presence&.to_i
    entity     = params[:entity_type].presence || "parcela"
    exclude_neighbor_ids = Array(params[:exclude_neighbor_ids]).map(&:to_i)
    excluded_ids = [exclude_id, *exclude_neighbor_ids].compact
    excluded_ids = [0] if excluded_ids.empty?
    return render json: { issues: [] } if coords.blank? || coords.length < 3

    pts  = coords.map { |c| [c[0].to_f, c[1].to_f] }
    ring = pts.map { |x, y| "#{x} #{y}" }.join(", ")
    ring += ", #{pts.first[0]} #{pts.first[1]}" unless pts.first == pts.last
    wkt  = "POLYGON((#{ring}))"

    overlap_min   = 0.10
    sliver_max_mp = 1.00
    sliver_dist   = 1.00

    issues = []

    # ── Suprapuneri cu același tip ──────────────────────────────────────
    kind        = entity == "cladire" ? "cladire" : "parcela"
    target_join = entity == "cladire" ? cladiri_geom_join : parcele_geom_join
    overlap_sql = ApplicationRecord.sanitize_sql_array([<<~SQL, wkt, excluded_ids, overlap_min])
      WITH np AS (SELECT ST_GeomFromText(?, 3844) AS geom)
      SELECT t.entity_id AS id, t.label,
        ST_Area(ST_Intersection(t.geom, np.geom)) AS area,
        ST_AsGeoJSON(ST_Intersection(t.geom, np.geom), 6) AS geojson
      FROM (#{target_join}) t, np
      WHERE t.entity_id NOT IN (?)
        AND ST_Intersects(t.geom, np.geom)
        AND ST_Area(ST_Intersection(t.geom, np.geom)) > ?
    SQL
    ActiveRecord::Base.connection.select_all(overlap_sql).each do |row|
      area_mp = row["area"].to_f
      # Suprapunerile ≤ 1 mp = fixabile prin snap pe vertecșii vecinilor.
      # Cele > 1 mp = hard block (necesită corectură manuală).
      issues << {
        type: "overlap", severity: "error", neighbor_kind: kind,
        neighbor_id: row["id"], neighbor_label: row["label"],
        area: area_mp.round(3),
        fixable: area_mp <= sliver_max_mp,
        message: "Suprapunere cu #{kind} #{row['label']}: #{area_mp.round(2)} mp",
        geojson: row["geojson"]
      }
    end

    # ── Slivers (gap-uri mici, < 1 mp) între parcele ─────────────────────
    # Pragul inferior e epsilon (0.01 mp) ca să nu raportăm zgomot de
    # floating-point dar să prindem orice gap real, oricât de mic — exact
    # acelea greu vizibile pe hartă care altfel scapă inspecției manuale.
    gap_min = 0.01
    sliver_sql = ApplicationRecord.sanitize_sql_array([<<~SQL, wkt, sliver_dist, excluded_ids, gap_min, sliver_max_mp])
      WITH np AS (SELECT ST_GeomFromText(?, 3844) AS geom),
           pairs AS (
             SELECT p.entity_id AS id, p.label, p.geom
             FROM (#{parcele_geom_join}) p, np
             WHERE ST_DWithin(p.geom, np.geom, ?)
               AND p.entity_id NOT IN (?)
               AND NOT ST_Overlaps(p.geom, np.geom)
               AND NOT ST_Touches(p.geom, np.geom)
           ),
           gaps AS (
             SELECT pairs.id, pairs.label,
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
      # Toate slivers (< 1 mp) sunt EROARE acum + fixabile prin snap pe vecini.
      issues << {
        type: "sliver", severity: "error", neighbor_kind: "parcela",
        neighbor_id: row["neighbor_id"], neighbor_label: row["neighbor_label"],
        area: row["gap_area"].to_f,
        fixable: true,
        message: "Gol față de parcela #{row['neighbor_label']}: #{row['gap_area']} mp",
        geojson: row["geojson"]
      }
    end

    # ── Vertex-on-vertex A→B (vertex nou pe muchia vecinului fără corespondent) ──
    vov_sql = ApplicationRecord.sanitize_sql_array([<<~SQL, wkt, wkt])
      WITH np AS (SELECT ST_GeomFromText(?, 3844) AS geom),
           new_verts AS (
             SELECT (ST_DumpPoints(ST_GeomFromText(?, 3844))).geom AS pt
           ),
           neighbors AS (
             SELECT p.entity_id AS id, p.label, p.geom
             FROM (#{parcele_geom_join}) p, np
             WHERE ST_DWithin(p.geom, np.geom, 0.5)
               AND p.entity_id NOT IN (#{excluded_ids.join(',')})
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

    # ── Vertex-on-vertex B→A (vertex vecin pe muchia poligonului nou) ───
    vov_rev_sql = ApplicationRecord.sanitize_sql_array([<<~SQL, wkt, wkt])
      WITH np AS (SELECT ST_GeomFromText(?, 3844) AS geom),
           new_verts AS (
             SELECT (ST_DumpPoints(ST_GeomFromText(?, 3844))).geom AS pt
           ),
           neighbors AS (
             SELECT p.entity_id AS id, p.label, p.geom
             FROM (#{parcele_geom_join}) p, np
             WHERE ST_DWithin(p.geom, np.geom, 0.5)
               AND p.entity_id NOT IN (#{excluded_ids.join(',')})
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

    # ── Clădire în parcele diferite ─────────────────────────────────────
    if entity == "cladire"
      cross_sql = ApplicationRecord.sanitize_sql_array([<<~SQL, wkt])
        WITH np AS (SELECT ST_GeomFromText(?, 3844) AS geom),
             vts AS (SELECT (ST_DumpPoints(np.geom)).geom AS pt FROM np)
        SELECT DISTINCT p.entity_id AS id, p.label,
          ST_AsGeoJSON(p.geom, 6) AS geojson
        FROM (#{parcele_geom_join}) p, vts
        WHERE ST_Intersects(p.geom, vts.pt)
      SQL
      parcele_atinse = ActiveRecord::Base.connection.select_all(cross_sql).to_a
      if parcele_atinse.size > 1
        labels = parcele_atinse.map { |r| r["label"] }.join(", ")
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

  # Export zona selectată: parcele + clădiri intersectate cu poligonul dat.
  def export_zone
    area_wkt = params[:area_wkt]
    format   = params[:format].to_s.downcase
    layers   = Array(params[:layers]).map(&:to_s)
    layers   = ["parcele", "cladiri"] if layers.empty?
    return head :bad_request if area_wkt.blank?

    features = collect_features_in_zone(area_wkt, layers)
    return head :no_content if features.empty?

    timestamp = Time.current.strftime("%Y%m%d_%H%M%S")
    case format
    when "dxf"
      send_data build_dxf_multi(features),
                filename: "export_#{timestamp}.dxf",
                type: "application/dxf", disposition: "attachment"
    when "kml"
      send_data build_kml(features),
                filename: "export_#{timestamp}.kml",
                type: "application/vnd.google-earth.kml+xml", disposition: "attachment"
    when "gpkg"
      data = build_gpkg(features)
      return render plain: "GPKG: ogr2ogr nu e instalat pe server. Instalează gdal-bin.", status: :unprocessable_entity if data.nil?
      send_data data,
                filename: "export_#{timestamp}.gpkg",
                type: "application/geopackage+sqlite3", disposition: "attachment"
    else
      head :bad_request
    end
  rescue => e
    Rails.logger.error("[export_zone] #{e.class}: #{e.message}")
    render plain: "Eroare export: #{e.message}", status: :unprocessable_entity
  end

  # Import DXF: creează Lands/Buildings drafturi cu geometrii din DXF.
  def import_dxf
    items    = params[:items]
    defaults = params[:defaults]&.permit!&.to_h || {}
    return render json: { ok: false, error: "items lipsă" }, status: :unprocessable_entity if items.blank?

    timestamp = Time.current.strftime("%Y%m%d-%H%M%S")
    results = {
      parcela: { created: 0, errors: [] },
      cladire: { created: 0, errors: [] }
    }

    items.each_with_index do |item, idx|
      cat = item[:category] || item["category"]
      wkt = item[:geom_wkt] || item["geom_wkt"]
      next if wkt.blank?

      case cat
      when "parcela"
        result, err = create_land_draft(
          cadgenno: "#{DRAFT_PREFIX}-#{timestamp}-#{idx + 1}",
          usecategory: defaults["categoria_folosinta"].presence || "neproductiv",
          geom_wkt: wkt
        )
        result ? (results[:parcela][:created] += 1) : (results[:parcela][:errors] << "##{idx + 1}: #{err}")

      when "cladire"
        result, err = create_building_draft(
          cadgenno: "#{DRAFT_PREFIX}-#{timestamp}-C#{idx + 1}",
          geom_wkt: wkt
        )
        result ? (results[:cladire][:created] += 1) : (results[:cladire][:errors] << "##{idx + 1}: #{err}")

      when "sector"
        results[:parcela][:errors] << "##{idx + 1}: categoria 'sector' nu e încă implementată"
      end
    end

    render json: { ok: true, results: results }
  rescue => e
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  end

  # Parsează un fișier KML/GPKG/DXF via ogr2ogr și întoarce poligoanele grupate
  # pe layer, cu coordonate în EPSG:3844 (Stereo70). (Pur de parsing, no DB.)
  def parse_geo_file
    upload = params[:file]
    return render json: { ok: false, error: "fișier lipsă" }, status: :unprocessable_entity unless upload.respond_to?(:read)

    ext = File.extname(upload.original_filename.to_s).downcase.delete_prefix(".")
    unless %w[kml gpkg dxf].include?(ext)
      return render json: { ok: false, error: "extensie neacceptată: .#{ext} (acceptate: .dxf, .kml, .gpkg)" },
                    status: :unprocessable_entity
    end

    Dir.mktmpdir("geo_import_") do |dir|
      in_path  = File.join(dir, "input.#{ext}")
      out_path = File.join(dir, "out.geojson")
      File.binwrite(in_path, upload.read)

      cmd = "ogr2ogr -f GeoJSON -t_srs EPSG:3844 -dim XY #{Shellwords.escape(out_path)} #{Shellwords.escape(in_path)} 2>&1"
      out = `#{cmd}`
      unless $?.success? && File.exist?(out_path)
        return render json: { ok: false, error: "ogr2ogr a eșuat: #{out.strip[0, 300]}" },
                      status: :unprocessable_entity
      end

      geo = JSON.parse(File.read(out_path))
      layers = Hash.new { |h, k| h[k] = [] }

      Array(geo["features"]).each do |feat|
        geom = feat["geometry"]
        next if geom.nil?
        props = feat["properties"] || {}
        layer_name = props["Layer"] || props["layer"] || props["Folder"] || props["Name"] || File.basename(upload.original_filename, ".*")
        layer_name = layer_name.to_s.presence || "default"

        polygons = case geom["type"]
                   when "Polygon"      then [geom["coordinates"]]
                   when "MultiPolygon" then geom["coordinates"]
                   else []
                   end
        polygons.each do |rings|
          ring = Array(rings).first
          next if ring.nil? || ring.length < 4
          coords = ring.map { |c| [c[0].to_f, c[1].to_f] }
          coords.pop if coords.length > 1 && coords.first == coords.last
          next if coords.length < 3
          layers[layer_name] << coords
        end
      end

      if layers.empty?
        render json: { ok: false, error: "Niciun poligon găsit în fișier (acceptate: Polygon / MultiPolygon)." },
               status: :unprocessable_entity
      else
        render json: { ok: true, layers: layers }
      end
    end
  rescue => e
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  end

  # Audit topologie global — scanează drafturile + cgxml lands/buildings.
  def audit_topologie
    issues = []

    # 1. Overlaps drafturi parcele
    sql = <<~SQL
      SELECT a.gis_id AS id_a, a.label AS label_a,
             b.gis_id AS id_b, b.label AS label_b,
             ROUND(ST_Area(ST_Intersection(a.geom, b.geom))::numeric, 2) AS area,
             ST_AsGeoJSON(ST_Intersection(a.geom, b.geom), 6) AS geojson
      FROM (#{parcele_geom_join}) a, (#{parcele_geom_join}) b
      WHERE a.gis_id < b.gis_id
        AND ST_Intersects(a.geom, b.geom)
        AND ST_Area(ST_Intersection(a.geom, b.geom)) > 0.10
      ORDER BY ST_Area(ST_Intersection(a.geom, b.geom)) DESC
      LIMIT 200
    SQL
    ActiveRecord::Base.connection.select_all(sql).each do |row|
      issues << {
        category: "Suprapuneri parcele",
        type: "overlap_parcele", severity: "error",
        message: "Parcela #{row['label_a']} ⇄ #{row['label_b']}: #{row['area']} mp",
        area: row['area'].to_f, geojson: row['geojson']
      }
    end

    # 2. Overlaps drafturi clădiri
    sql = <<~SQL
      SELECT a.gis_id AS id_a, a.label AS label_a,
             b.gis_id AS id_b, b.label AS label_b,
             ROUND(ST_Area(ST_Intersection(a.geom, b.geom))::numeric, 2) AS area,
             ST_AsGeoJSON(ST_Intersection(a.geom, b.geom), 6) AS geojson
      FROM (#{cladiri_geom_join}) a, (#{cladiri_geom_join}) b
      WHERE a.gis_id < b.gis_id
        AND ST_Intersects(a.geom, b.geom)
        AND ST_Area(ST_Intersection(a.geom, b.geom)) > 0.10
      ORDER BY ST_Area(ST_Intersection(a.geom, b.geom)) DESC
      LIMIT 200
    SQL
    ActiveRecord::Base.connection.select_all(sql).each do |row|
      issues << {
        category: "Suprapuneri clădiri",
        type: "overlap_cladiri", severity: "error",
        message: "Clădirea #{row['label_a']} ⇄ #{row['label_b']}: #{row['area']} mp",
        area: row['area'].to_f, geojson: row['geojson']
      }
    end

    # CTE pentru lands/buildings cu geometrie reconstruită din points (cgxml import)
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
      cgxml_lands_v AS (SELECT id, label, geom FROM cgxml_lands WHERE ST_IsValid(geom))
    SQL

    # 3a. Drafturi vs CGXML lands (divergențe)
    sql = "#{cgxml_polys_cte}\n" + <<~SQL
      SELECT p.gis_id AS id_a, p.label AS label_a,
             cl.id AS id_b, cl.label AS label_b,
             ROUND(ST_Area(ST_Intersection(p.geom, cl.geom))::numeric, 2) AS area,
             ST_AsGeoJSON(ST_Intersection(p.geom, cl.geom), 6) AS geojson
      FROM (#{parcele_geom_join}) p, cgxml_lands_v cl
      WHERE ST_Intersects(p.geom, cl.geom)
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
        area: row['area'].to_f, geojson: row['geojson']
      }
    end

    # 3b. CGXML lands ↔ CGXML lands
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
        area: row['area'].to_f, geojson: row['geojson']
      }
    end

    # 4. Clădiri ce traversează mai multe parcele
    sql = <<~SQL
      WITH cladiri_verts AS (
        SELECT c.gis_id AS cladire_id, c.label AS cladire_label, c.geom AS cladire_geom,
               (ST_DumpPoints(c.geom)).geom AS pt
        FROM (#{cladiri_geom_join}) c
      ),
      mapped AS (
        SELECT cv.cladire_id, cv.cladire_label, cv.cladire_geom,
               COUNT(DISTINCT p.gis_id) AS parcele_count,
               string_agg(DISTINCT p.label, ', ') AS parcele_labels
        FROM cladiri_verts cv
        JOIN (#{parcele_geom_join}) p ON ST_Intersects(p.geom, cv.pt)
        GROUP BY cv.cladire_id, cv.cladire_label, cv.cladire_geom
        HAVING COUNT(DISTINCT p.gis_id) > 1
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

    by_cat = issues.group_by { |i| i[:category] }
    categories = by_cat.map { |name, items| { name: name, count: items.size, severity: items.first[:severity] } }

    render json: { total: issues.size, categories: categories, issues: issues }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # Salvare topology-aware în 2 faze. payload = { primary: {kind, id, geom_wkt}, neighbors: [...] }
  # kind = 'parcela' | 'cladire'; id = id-ul Land/Building (existent sau null pentru create).
  def save_batch
    primary   = params[:primary]
    neighbors = params[:neighbors] || []
    return render json: { ok: false, errors: ["primary lipsește"] }, status: :unprocessable_entity if primary.blank?

    errors = []
    redirect_url = nil

    ActiveRecord::Base.transaction do
      pre_overlaps = {}
      records_with_payloads = []
      [primary, *neighbors].each do |payload|
        kind = payload[:kind] || payload["kind"]
        id   = payload[:id]   || payload["id"]
        next unless id.present?
        record = kind == "cladire" ? Building.find_by(id: id) : Land.find_by(id: id)
        next unless record
        record.gis_geometry || (kind == "cladire" ? record.build_gis_geometry(status: "draft") : record.build_gis_geometry(status: "draft"))
        pre_overlaps[[record.class.name, record.id]] = capture_overlap_set(record)
        records_with_payloads << [record, payload]
      end

      # Faza 1: save fără overlap-check (geometriile simultan).
      # Flag-ul Thread.current se setează ÎN INTERIORUL begin pentru ca eventuale
      # exceptii ridicate înainte de assignment (improbabil, dar posibil la
      # context-switch) să nu lase flag-ul lipit de thread-ul Puma → pollution.
      begin
        Thread.current[:topology_skip_overlap_check] = true
        records_with_payloads.each do |record, payload|
          phase1_save_record(record, payload, errors)
        end
      ensure
        Thread.current[:topology_skip_overlap_check] = nil
      end
      raise ActiveRecord::Rollback if errors.any?

      # Faza 2: alte validări (topologic_valid, traverseaza_parcele)
      begin
        Thread.current[:topology_skip_overlap_check] = true
        records_with_payloads.each do |record, _|
          record.reload
          g = record.gis_geometry
          next if g&.valid?
          kind  = record.is_a?(Building) ? "cladire" : "parcela"
          label = record.label
          g&.errors&.full_messages&.each { |m| errors << "#{kind} #{label}: #{m}" }
        end
      ensure
        Thread.current[:topology_skip_overlap_check] = nil
      end
      raise ActiveRecord::Rollback if errors.any?

      # Faza 3: delta-check pe overlap (raportăm doar pe cele NOI)
      records_with_payloads.each do |record, _|
        post = capture_overlap_set(record)
        pre  = pre_overlaps[[record.class.name, record.id]] || Set.new
        new_overlaps = post - pre
        kind = record.is_a?(Building) ? "cladire" : "parcela"
        label = record.label
        new_overlaps.each do |other_id, other_label, area|
          errors << "#{kind} #{label}: overlap NOU cu #{kind} #{other_label} (#{area} mp)"
        end
      end
      raise ActiveRecord::Rollback if errors.any?

      kind = primary[:kind] || primary["kind"]
      id   = primary[:id]   || primary["id"]
      redirect_url = kind == "cladire" ? "/buildings/#{id}" : "/lands/#{id}"
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

    pts  = coords.map { |c| [c[0].to_f, c[1].to_f] }
    ring = pts.map { |x, y| "#{x} #{y}" }.join(", ")
    ring += ", #{pts.first[0]} #{pts.first[1]}" unless pts.first == pts.last
    wkt = "POLYGON((#{ring}))"

    sql = ApplicationRecord.sanitize_sql_array(
      ["SELECT ROUND(ST_Area(ST_SetSRID(ST_GeomFromText(?), 3844))::numeric, 4)", wkt]
    )
    suprafata = ActiveRecord::Base.connection.select_value(sql).to_f

    is_valid  = ActiveRecord::Base.connection.select_value(
      ApplicationRecord.sanitize_sql_array(["SELECT ST_IsValid(ST_SetSRID(ST_GeomFromText(?), 3844))", wkt])
    )
    is_simple = ActiveRecord::Base.connection.select_value(
      ApplicationRecord.sanitize_sql_array(["SELECT ST_IsSimple(ST_SetSRID(ST_GeomFromText(?), 3844))", wkt])
    )

    render json: {
      suprafata: suprafata,
      is_valid: is_valid == "t" || is_valid == true,
      is_simple: is_simple == "t" || is_simple == true
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
    wkt = "POLYGON((#{ring}))"

    sql = ApplicationRecord.sanitize_sql_array([<<~SQL, wkt, wkt])
      SELECT g.land_id AS id, COALESCE(l.cadgenno, 'L#' || l.id) AS numar_cadastral
      FROM gis_land_geometries g
      JOIN lands l ON l.id = g.land_id
      WHERE ST_Intersects(g.geom, ST_GeomFromText(?, 3844))
      ORDER BY ST_Area(ST_Intersection(g.geom, ST_GeomFromText(?, 3844))) DESC
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
    wkt = "POLYGON((#{ring}))"

    sql = ApplicationRecord.sanitize_sql_array([<<~SQL, wkt])
      WITH poly AS (SELECT ST_Centroid(ST_GeomFromText(?, 3844)) AS centroid)
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
      filename: "#{name.parameterize}_#{Time.current.strftime('%Y%m%d_%H%M%S')}.dxf",
      type: "application/dxf", disposition: "attachment"
  end

  # Curățare topologică pe o zonă (set de poligoane selectate).
  # Payload: { items: [{kind:"parcela"|"cladire", id:N}, ...], threshold: 0.5 }
  # Algoritm:
  #   1. Pentru fiecare poligon din set, ST_Snap la unionul tuturor celorlalte
  #      din set, cu toleranță = threshold (m). Acțiunile lui ST_Snap:
  #       - vertecșii apropiați de vertecșii vecinilor → snap pe acea poziție
  #         (unificarea vertecșilor pe laturi comune)
  #       - inserare vertex pe muchii unde un alt poligon are vertex
  #         (asigură că laturile comune au noduri pe ambele părți)
  #       - închide goluri / elimină suprapuneri ≤ toleranță
  #   2. Verifică ABS(area_new - area_old) ≤ 1.0 mp → dacă DA, persistă;
  #      altfel, sare (nu modifică), păstrând invarianta de suprafață.
  #   3. Returnează rezumat: modificate / sărite / erori.
  # ── Curățare topologică conservativă pe selecție ──────────────────────────
  # POST /digitizare/cleanup_topology
  # Aliniază muchiile dintre poligoanele SELECTATE (rezolvă slivere/gap-uri
  # mici) păstrând:
  #   - LOCKED: muchiile adiacente poligoanelor NESELECTATE NU se mișcă
  #     (nu modificăm limita cu vecini din afara selecției)
  #   - SHARED: vertecșii apropiați de alte poligoane selectate se snap-uiesc
  #     pe acestea (canonicalizare muchii comune)
  #   - FREE: vertecșii departe de orice poligon (facing empty space)
  #     rămân nemișcați (nu mutăm muchii care „pluteau" în gol)
  #
  # CONSERVARE ARIE: aria cadastrală (FLOOR mp) trebuie să rămână NESCHIMBATĂ.
  # Aceasta admite delta sub-metru (1000.01 → 1000.49 mp este OK, ambele
  # FLOOR la 1000 mp). Dacă FLOOR(old) ≠ FLOOR(new) → poligonul este SĂRIT
  # cu motiv explicit.
  #
  # Input:
  #   items: [{ kind: 'parcela'|'cladire', id }]  — selecția curentă
  #   threshold: float, raza de snap în metri (default 0.50, max 5.0)
  # POST /digitizare/snap_to_linear
  # Alipirea automată a unui polygon la detaliile liniare vecine (drumuri, căi
  # ferate, canale, ape). Detecție prin `parcels.usecategory IN ('DR','CC','CN','A')`.
  # Vertex-level snap conservativ — păstrează aria cadastrală (FLOOR mp).
  # Input: { kind: 'parcela'|'cladire', id: int, threshold_m: float }
  def snap_to_linear
    kind        = (params[:kind] || "parcela").to_s
    eid         = params[:id].to_i
    threshold_m = params[:threshold_m].to_f
    threshold_m = 0.50 if threshold_m <= 0
    threshold_m = [[threshold_m, 0.05].max, 5.0].min
    linear_categories = %w[DR CC CN A]

    return render json: { ok: false, error: "ID polygon invalid" }, status: :bad_request if eid <= 0
    join_sql = (kind == "cladire") ? cladiri_geom_join : parcele_geom_join
    fk       = (kind == "cladire") ? "building_id"     : "land_id"
    model    = (kind == "cladire") ? GisBuildingGeometry : GisLandGeometry

    sql = ApplicationRecord.sanitize_sql_array([<<~SQL, eid, threshold_m, threshold_m])
      WITH selected AS (
        -- ST_Multi forțează MultiPolygon → ST_DumpPoints returnează path
        -- consistent cu 3 elemente [poly_idx, ring_idx, pt_idx].
        SELECT t.entity_id, t.label AS lbl, ST_Multi(ST_MakeValid(t.geom)) AS old_geom
        FROM   (#{join_sql}) t
        WHERE  t.entity_id = ? AND ST_IsValid(t.geom)
      ),
      linear_features AS (
        -- Polygons cu usecategory ∈ ('DR','CC','CN','A') în limita pragului
        SELECT ST_Union(ST_MakeValid(g.geom)) AS boundary
        FROM   gis_land_geometries g
        JOIN   parcels p ON p.land_id = g.land_id
        WHERE  p.usecategory IN ('DR','CC','CN','A')
          AND  ST_DWithin(g.geom, (SELECT old_geom FROM selected), ?)
          AND  g.land_id != (SELECT entity_id FROM selected WHERE 'parcela' = '#{kind}')
      ),
      linear_boundary AS (
        SELECT COALESCE(ST_Boundary(boundary), ST_GeomFromText('POINT EMPTY', 3844)) AS b
        FROM   linear_features
      ),
      poly_vertices AS (
        SELECT s.entity_id, s.lbl, s.old_geom,
               (ST_DumpPoints(s.old_geom)).path AS path,
               (ST_DumpPoints(s.old_geom)).geom AS pt
        FROM   selected s
      ),
      vertex_resolved AS (
        -- Pentru fiecare vertex: dacă există punct pe boundary-ul liniarelor
        -- în raza threshold → snap. Altfel rămâne.
        SELECT pv.entity_id, pv.lbl, pv.old_geom, pv.path,
               CASE
                 WHEN ST_IsEmpty((SELECT b FROM linear_boundary)) THEN pv.pt
                 WHEN ST_Distance(pv.pt, ST_ClosestPoint((SELECT b FROM linear_boundary), pv.pt)) <= ?
                 THEN ST_ClosestPoint((SELECT b FROM linear_boundary), pv.pt)
                 ELSE pv.pt
               END AS new_pt
        FROM   poly_vertices pv
      ),
      rings_built AS (
        SELECT entity_id, lbl, old_geom,
               path[1] AS poly_idx, path[2] AS ring_idx,
               ST_MakeLine(new_pt ORDER BY path[3]) AS ring_line
        FROM   vertex_resolved
        GROUP  BY entity_id, lbl, old_geom, path[1], path[2]
      ),
      new_polys AS (
        SELECT entity_id, lbl, old_geom,
               ST_Multi(ST_MakeValid(ST_BuildArea(ST_Collect(ring_line)))) AS raw_geom
        FROM   rings_built
        GROUP  BY entity_id, lbl, old_geom
      ),
      area_corrected AS (
        -- Scalare uniformă din centroid → aria EXACTĂ = old_area.
        -- Deplasare vertecși proporțională cu scale (mic dacă diferența mp este mică).
        -- Trade-off: vertecșii snap-uiți pe drum se pot mișca cu ~0.1-1m (în
        -- funcție de magnitudinea schimbării de arie).
        SELECT entity_id, lbl, old_geom,
               CASE
                 WHEN NOT ST_IsValid(raw_geom) OR ST_IsEmpty(raw_geom) THEN raw_geom
                 WHEN ST_Area(raw_geom) < 0.01 THEN raw_geom
                 WHEN ABS(ST_Area(raw_geom) - ST_Area(old_geom)) < 0.5 THEN raw_geom
                 ELSE ST_Multi(ST_MakeValid(ST_Affine(raw_geom,
                   sqrt(ST_Area(old_geom) / NULLIF(ST_Area(raw_geom), 0)),
                   0, 0,
                   sqrt(ST_Area(old_geom) / NULLIF(ST_Area(raw_geom), 0)),
                   (1 - sqrt(ST_Area(old_geom) / NULLIF(ST_Area(raw_geom), 0))) * ST_X(ST_Centroid(raw_geom)),
                   (1 - sqrt(ST_Area(old_geom) / NULLIF(ST_Area(raw_geom), 0))) * ST_Y(ST_Centroid(raw_geom))
                 )))
               END AS new_geom
        FROM   new_polys
      )
      SELECT entity_id, lbl,
             ROUND(ST_Area(old_geom)::numeric, 4)  AS old_area,
             ROUND(ST_Area(new_geom)::numeric, 4)  AS new_area,
             FLOOR(ST_Area(old_geom))::int         AS old_area_cad,
             FLOOR(ST_Area(new_geom))::int         AS new_area_cad,
             ST_IsValid(new_geom)                  AS valid_new,
             NOT ST_IsEmpty(new_geom)              AS nonempty,
             ST_AsText(new_geom)                   AS new_wkt
      FROM   area_corrected
    SQL

    row = ActiveRecord::Base.connection.select_one(sql)
    return render json: { ok: false, error: "Polygon negăsit sau invalid" }, status: :unprocessable_entity if row.nil?
    return render json: { ok: false, error: "Geometrie rezultată invalidă" }, status: :unprocessable_entity unless row["valid_new"] && row["nonempty"]

    old_cad = row["old_area_cad"].to_i
    new_cad = row["new_area_cad"].to_i
    delta   = (row["new_area"].to_f - row["old_area"].to_f).round(4)

    if old_cad != new_cad
      return render json: {
        ok: false,
        error: "Aria cadastrală s-ar schimba (#{old_cad} → #{new_cad} mp)",
        delta_mp: delta
      }, status: :unprocessable_entity
    end

    if delta.abs < 0.0001
      return render json: {
        ok: true, modified: false,
        message: "Niciun vertex în limita pragului — polygon deja aliniat."
      }
    end

    g = model.find_or_initialize_by(fk => eid)
    g.status   = "active" if g.new_record? && g.status.blank?
    g.geom_wkt = row["new_wkt"]
    Thread.current[:topology_skip_overlap_check] = true
    saved = g.save(validate: false)
    Thread.current[:topology_skip_overlap_check] = nil

    if saved
      render json: {
        ok: true, modified: true,
        label: row["lbl"], delta_mp: delta,
        old_area: row["old_area"].to_f, new_area: row["new_area"].to_f
      }
    else
      render json: { ok: false, error: "Salvare eșuată: #{g.errors.full_messages.join(", ")}" },
             status: :unprocessable_entity
    end
  rescue => e
    Rails.logger.error("snap_to_linear error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    render json: { ok: false, error: "Eroare server: #{e.message}" }, status: :internal_server_error
  end

  def cleanup_topology
    items     = params[:items] || []
    threshold = params[:threshold].presence&.to_f || 0.50
    return render json: { ok: false, error: "Niciun poligon selectat" }, status: :bad_request if items.empty?
    return render json: { ok: false, error: "Prag invalid" }, status: :bad_request if threshold <= 0 || threshold > 5

    land_ids     = items.select { |i| (i[:kind] || i["kind"]) == "parcela" }.map { |i| (i[:id] || i["id"]).to_i }.reject(&:zero?)
    building_ids = items.select { |i| (i[:kind] || i["kind"]) == "cladire" }.map { |i| (i[:id] || i["id"]).to_i }.reject(&:zero?)

    modified = []
    skipped  = []
    errors   = []

    # Tratează fiecare tip separat (lands ↔ lands, buildings ↔ buildings).
    [["parcela", land_ids,     parcele_geom_join, "land_id",     GisLandGeometry],
     ["cladire", building_ids, cladiri_geom_join, "building_id", GisBuildingGeometry]
    ].each do |kind, ids, join_sql, fk, model|
      next if ids.empty?

      # SQL: vertex-level snap conservativ.
      # 1) selected      = poligoanele din selecție
      # 2) non_selected  = poligoane vecine NESELECTATE în raza (threshold*2)
      # 3) lock_zone     = buffer(non_selected, threshold) — vertecșii aici NU se mută
      # 4) other_boundary[A] = ST_Boundary(union of selected EXCEPT A) — ținta snap
      # 5) Pentru fiecare vertex v al poligonului A:
      #      - dacă v ∈ lock_zone → rămâne în loc (LOCKED)
      #      - altfel dacă există punct pe other_boundary[A] în raza threshold
      #        → snap pe acel punct (SHARED — canonicalizare muchii comune)
      #      - altfel → rămâne în loc (FREE — facing empty space)
      # 6) Reconstrucție poligon din new_pt-uri, păstrând ordinea path-urilor
      # 7) Skip dacă FLOOR(old_area) ≠ FLOOR(new_area) (aria cadastrală schimbată)
      sql = ApplicationRecord.sanitize_sql_array([<<~SQL, ids, ids, threshold * 2, threshold, threshold])
        WITH selected AS (
          SELECT t.entity_id, t.label AS lbl, ST_MakeValid(t.geom) AS old_geom
          FROM   (#{join_sql}) t
          WHERE  t.entity_id IS NOT NULL AND t.entity_id IN (?) AND ST_IsValid(t.geom)
        ),
        selected_union AS (
          SELECT ST_UnaryUnion(ST_Collect(old_geom)) AS u FROM selected
        ),
        non_selected AS (
          -- Poligoane NESELECTATE din vecinătate (definesc lock_zone)
          SELECT ST_Union(ST_MakeValid(t.geom)) AS u
          FROM   (#{join_sql}) t
          WHERE  t.entity_id IS NOT NULL AND t.entity_id NOT IN (?)
            AND  ST_DWithin(t.geom, (SELECT u FROM selected_union), ?)
        ),
        lock_zone AS (
          -- LOCK = buffer(threshold) în jurul poligoanelor neselectate
          SELECT COALESCE(
            ST_Buffer((SELECT u FROM non_selected), ?),
            ST_GeomFromText('POLYGON EMPTY', 3844)
          ) AS g
        ),
        poly_vertices AS (
          -- Toți vertecșii fiecărui poligon cu path = [poly_idx, ring_idx, pt_idx]
          SELECT s.entity_id, s.lbl, s.old_geom,
                 (ST_DumpPoints(s.old_geom)).path AS path,
                 (ST_DumpPoints(s.old_geom)).geom AS pt
          FROM   selected s
        ),
        other_boundary AS (
          -- Pentru fiecare poligon A: boundary-ul UNIUNII poligoanelor selectate
          -- EXCEPT A — ținta de snap pentru vertecșii SHARED.
          SELECT s1.entity_id,
                 ST_Boundary(ST_UnaryUnion(ST_Collect(s2.old_geom))) AS b
          FROM   selected s1
          JOIN   selected s2 ON s2.entity_id != s1.entity_id
          GROUP  BY s1.entity_id
        ),
        vertex_resolved AS (
          SELECT pv.entity_id, pv.lbl, pv.old_geom, pv.path, pv.pt,
                 CASE
                   -- LOCKED: vertex în lock_zone → NU se mută
                   WHEN ST_Intersects(pv.pt, (SELECT g FROM lock_zone)) THEN pv.pt
                   -- SHARED: vertex aproape de alt poligon selectat → snap pe el
                   ELSE COALESCE(
                     (SELECT
                       CASE WHEN ST_Distance(pv.pt, ST_ClosestPoint(ob.b, pv.pt)) <= ?
                         THEN ST_ClosestPoint(ob.b, pv.pt)
                         ELSE pv.pt
                       END
                      FROM other_boundary ob
                      WHERE ob.entity_id = pv.entity_id),
                     pv.pt  -- FREE sau singur poligon: rămâne în loc
                   )
                 END AS new_pt
          FROM   poly_vertices pv
        ),
        rings_built AS (
          SELECT entity_id, lbl, old_geom,
                 path[1] AS poly_idx, path[2] AS ring_idx,
                 ST_MakeLine(new_pt ORDER BY path[3]) AS ring_line
          FROM   vertex_resolved
          GROUP  BY entity_id, lbl, old_geom, path[1], path[2]
        ),
        new_polys AS (
          SELECT entity_id, lbl, old_geom,
                 ST_Multi(ST_MakeValid(ST_BuildArea(ST_Collect(ring_line)))) AS new_geom
          FROM   rings_built
          GROUP  BY entity_id, lbl, old_geom
        )
        SELECT entity_id, lbl,
               ROUND(ST_Area(old_geom)::numeric, 4)  AS old_area,
               ROUND(ST_Area(new_geom)::numeric, 4)  AS new_area,
               FLOOR(ST_Area(old_geom))::int         AS old_area_cad,
               FLOOR(ST_Area(new_geom))::int         AS new_area_cad,
               ST_IsValid(new_geom)                  AS valid_new,
               NOT ST_IsEmpty(new_geom)              AS nonempty,
               ST_AsText(new_geom)                   AS new_wkt
        FROM   new_polys
      SQL

      rows = ActiveRecord::Base.connection.select_all(sql).to_a
      rows.each do |r|
        eid = r["entity_id"].to_i
        next if eid <= 0   # rânduri orfane (entity_id NULL în date legacy) — skip silent

        unless r["valid_new"] && r["nonempty"]
          skipped << { kind: kind, entity_id: eid, label: r["lbl"], reason: "geometrie rezultată invalidă/goală" }
          next
        end

        old_a   = r["old_area"].to_f
        new_a   = r["new_area"].to_f
        old_cad = r["old_area_cad"].to_i
        new_cad = r["new_area_cad"].to_i
        delta   = (new_a - old_a).round(4)

        # CONSERVARE ARIE: aria cadastrală (FLOOR mp) trebuie să rămână aceeași.
        if old_cad != new_cad
          skipped << {
            kind: kind, entity_id: eid, label: r["lbl"],
            delta: delta, old_cad: old_cad, new_cad: new_cad,
            reason: "aria cadastrală s-ar schimba (#{old_cad} → #{new_cad} mp, delta geom #{delta} mp)"
          }
          next
        end

        # Dacă delta e zero (vertecșii reali n-au avut țintă utilă) → skip
        # raportat (pentru transparență — user vede de ce un poligon selectat
        # n-a fost modificat).
        if delta.abs < 0.0001
          skipped << {
            kind: kind, entity_id: eid, label: r["lbl"],
            delta: delta, reason: "niciun vertex util — toate LOCKED sau FREE (fără țintă de snap)"
          }
          next
        end

        # Persistă prin model (NU raw SQL) — păstrează compute_derived +
        # consistență cu restul aplicației.
        g = model.find_or_initialize_by(fk => eid)
        g.status   = "active" if g.new_record? && g.status.blank?
        g.geom_wkt = r["new_wkt"]
        begin
          Thread.current[:topology_skip_overlap_check] = true
          if g.save(validate: false)
            modified << {
              kind: kind, entity_id: eid, label: r["lbl"],
              old_area: old_a, new_area: new_a, delta: delta,
              area_cad: old_cad
            }
          else
            errors << { kind: kind, entity_id: eid, label: r["lbl"], message: g.errors.full_messages.join(", ").presence || "save returned false" }
          end
        rescue => e
          errors << { kind: kind, entity_id: eid, label: r["lbl"], message: e.message }
        ensure
          Thread.current[:topology_skip_overlap_check] = nil
        end
      end
    end

    # Audit independent — recitește din BD ce s-a salvat și confirmă invariantul
    # FLOOR(saved_area) == FLOOR(original_area). Plasă de siguranță împotriva
    # drift-ului între ce promite algoritmul SQL și ce ajunge în BD prin
    # compute_derived. Audit failures → ok=false în răspuns (anomalie serioasă).
    audit_report = audit_cleanup_areas(modified)

    render json: {
      ok:        errors.empty? && audit_report[:failed] == 0,
      threshold: threshold,
      modified:  modified,
      skipped:   skipped,
      errors:    errors,
      audit:     audit_report,
      summary:   "Modificate #{modified.length}, sărite #{skipped.length}, erori #{errors.length}, audit fail #{audit_report[:failed]}"
    }
  rescue => e
    render json: { ok: false, error: "Eroare server: #{e.message}" }, status: :internal_server_error
  end

  # ── Buffer ax linie + listare vecini afectați (drumuri, detalii liniare) ──
  # POST /digitizare/buffer_drum
  # Input:
  #   line_wkt — LINESTRING WKT în EPSG:3844 (axul detaliului liniar)
  #   width_m  — lățime totală (float > 0); offset = width/2 stânga + dreapta
  # Output:
  #   geojson — Polygon BANDA UNIFORMĂ (NEclipată); drumul are lățime continuă
  #   affected_neighbors — array [{ kind, id, new_geojson, area_delta_mp }]
  #     poligoanele vecine (parcele + clădiri) care intersectează banda, cu
  #     geometriile NOI calculate prin ST_Difference (vecin - drum). User-ul
  #     poate ajusta manual aceste geometrii înainte de save.
  def buffer_drum
    line_wkt    = params[:line_wkt].to_s.strip
    width_m     = params[:width_m].to_f
    snap_dist_m = sanitize_snap_dist(params[:snap_dist_m])
    return render json: { ok: false, error: "Linie absentă" },          status: :bad_request if line_wkt.blank?
    return render json: { ok: false, error: "Lățime invalidă (0..50)" }, status: :bad_request if width_m <= 0 || width_m > 50

    # Calculează banda drumului + vecinii afectați (vezi compute_drum_geometry).
    # AMBELE buffer_drum (preview) și save_drum (persistare) folosesc același
    # helper → garanție că ce vezi e ce se salvează.
    result = compute_drum_geometry(line_wkt, width_m, snap_dist_m)
    return render json: { ok: false, error: "Buffer linie eșuat" }, status: :unprocessable_entity if result.nil?
    band = result[:band]
    ui_neighbors = result[:neighbors].map do |n|
      {
        kind:          n[:kind],
        id:            n[:entity_id],
        new_geojson:   n[:new_geojson],
        delete:        n[:delete],
        old_area_mp:   n[:old_area],
        new_area_mp:   n[:new_area],
        area_delta_mp: n[:area_delta],
        reason:        n[:reason]
      }
    end

    # Zonă vizuală de prag — inel între limita drumului și limita+snap_dist,
    # arată utilizatorului zona în care vecinii vor fi alipiți la drum.
    zone_sql = ApplicationRecord.sanitize_sql_array([<<~SQL, band[:wkt], snap_dist_m])
      WITH band AS (SELECT ST_GeomFromText(?, 3844) AS geom),
           buffered AS (SELECT ST_Buffer((SELECT geom FROM band), ?) AS geom)
      SELECT ST_AsGeoJSON(ST_Difference((SELECT geom FROM buffered), (SELECT geom FROM band)), 6) AS geojson
    SQL
    zone_row = ActiveRecord::Base.connection.select_one(zone_sql) || {}

    # Diagnostic: număr candidați găsiți (parcele + clădiri) în limita pragului.
    diag_sql = ApplicationRecord.sanitize_sql_array([<<~SQL, band[:wkt], snap_dist_m, band[:wkt], snap_dist_m])
      SELECT
        (SELECT COUNT(*) FROM (#{parcele_geom_join}) t
         WHERE t.entity_id IS NOT NULL AND ST_DWithin(t.geom, ST_GeomFromText(?, 3844), ?)) AS parcele_in_range,
        (SELECT COUNT(*) FROM (#{cladiri_geom_join}) t
         WHERE t.entity_id IS NOT NULL AND ST_DWithin(t.geom, ST_GeomFromText(?, 3844), ?)) AS cladiri_in_range
    SQL
    diag = ActiveRecord::Base.connection.select_one(diag_sql) || {}

    render json: {
      ok:                 true,
      geojson:            band[:geojson],
      area_mp:            band[:area_mp],
      nverts:             band[:nverts],
      snap_zone_geojson:  zone_row["geojson"] ? JSON.parse(zone_row["geojson"]) : nil,
      affected_neighbors: ui_neighbors,
      diagnostic: {
        parcele_in_range:  diag["parcele_in_range"].to_i,
        cladiri_in_range:  diag["cladiri_in_range"].to_i,
        affected_returned: ui_neighbors.length
      }
    }
  rescue => e
    Rails.logger.error("buffer_drum error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    render json: { ok: false, error: "Eroare server: #{e.message}" }, status: :internal_server_error
  end

  # ── Save drum + actualizare atomică vecini afectați ───────────────────────
  # POST /digitizare/save_drum
  # Creează un nou Land (drumul) + actualizează geometriile parcelelor/clădirilor
  # afectate ÎN ACEEAȘI TRANZACȚIE → garantează că la sfârșit nu există overlap-uri
  # (drumul ocupă spațiul subtras din vecini).
  #
  # SECURITATE: clientul NU mai trimite geometrii (nici drumul, nici vecinii).
  # Trimite DOAR axa + parametri (axis_wkt, width_m, snap_dist_m); serverul
  # recalculează banda drumului + geometriile vecinilor prin compute_drum_geometry
  # (același cod ca buffer_drum). Previne injectarea de poligoane arbitrare
  # care ar putea suprapune mii de parcele.
  #
  # Input:
  #   axis_wkt    — LINESTRING WKT al axei (EPSG:3844), trasat de utilizator
  #   width_m     — lățime totală drum (float > 0, <= 50)
  #   snap_dist_m — prag alipire vecini (clamp [0.5..20], default 5)
  #   road: { cadgenno, suprafata_mp, categoria_folosinta }  — metadate
  def save_drum
    axis_wkt    = params[:axis_wkt].to_s.strip
    width_m     = params[:width_m].to_f
    snap_dist_m = sanitize_snap_dist(params[:snap_dist_m])
    road        = params.require(:road).permit(:cadgenno, :suprafata_mp, :categoria_folosinta)

    return render json: { ok: false, errors: ["Axa drumului lipsește"] },     status: :unprocessable_entity if axis_wkt.blank?
    return render json: { ok: false, errors: ["Lățime invalidă (0..50)"] },   status: :unprocessable_entity if width_m <= 0 || width_m > 50

    # Recalculează geometria server-side — DEFENSIVE: clientul nu controlează
    # poligonul drumului sau al vecinilor. Garantează că ce se salvează =
    # exact ce a fost previzualizat prin buffer_drum (același helper).
    result = compute_drum_geometry(axis_wkt, width_m, snap_dist_m)
    return render json: { ok: false, errors: ["Calcul band drum eșuat"] }, status: :unprocessable_entity if result.nil?

    band               = result[:band]
    computed_neighbors = result[:neighbors]

    errors      = []
    new_land_id = nil

    ActiveRecord::Base.transaction do
      # 1. Creare drum (nou Land + gis_land_geometry draft).
      # measuredarea fallback la aria calculată dacă clientul n-a trimis-o —
      # nu blocăm save-ul pentru un câmp metadata.
      land = Land.new(
        cadgenno:     road[:cadgenno].presence,
        measuredarea: road[:suprafata_mp].presence&.to_f || band[:area_mp],
        isnew:        true,
        notes:        "Drum / detaliu liniar (digitizat #{Date.current})"
      )
      unless land.save(validate: false)
        errors.concat(land.errors.full_messages.map { |m| "Drum land: #{m}" })
        raise ActiveRecord::Rollback
      end
      new_land_id = land.id
      g = land.build_gis_geometry(status: "draft", geom_wkt: band[:wkt])
      # save(validate: false) — geometria garantat validă (PostGIS ST_MakeValid
      # în compute_drum_geometry). Sărim overlap-check pentru că drumul va fi
      # alipit la vecini → temporar suprapunere până la save-ul vecinilor.
      unless g.save(validate: false)
        errors << "Drum: salvare geom eșuată (#{g.errors.full_messages.join(', ')})"
        raise ActiveRecord::Rollback
      end
      if road[:categoria_folosinta].present?
        Parcel.create!(land_id: land.id, usecategory: road[:categoria_folosinta], number: 1)
      end

      # 2. Aplică modificările pe vecini (geometriile RECALCULATE de server).
      begin
        Thread.current[:topology_skip_overlap_check] = true
        computed_neighbors.each do |n|
          eid = n[:entity_id].to_i
          next if eid <= 0
          kind = n[:kind]
          rec = kind == "cladire" ? Building.find_by(id: eid) : Land.find_by(id: eid)
          unless rec
            errors << "Vecin #{kind}##{eid} inexistent"
            next
          end
          # delete=true → drumul absoarbe integral vecinul.
          if n[:delete]
            unless rec.destroy
              errors << "Vecin #{kind}##{eid}: ștergere eșuată (#{rec.errors.full_messages.first})"
            end
            next
          end
          next if n[:new_wkt].blank?
          gn = rec.gis_geometry || rec.send(:build_gis_geometry, status: "draft")
          gn.geom_wkt = n[:new_wkt]
          begin
            unless gn.save(validate: false)
              msg = gn.errors.full_messages.join(", ").presence || "save returned false"
              errors << "Vecin #{kind}##{eid}: #{msg}"
              Rails.logger.error("save_drum vecin #{eid} failed: #{msg}")
            end
          rescue => save_err
            errors << "Vecin #{kind}##{eid}: #{save_err.message}"
            Rails.logger.error("save_drum vecin #{eid} exception: #{save_err.class}: #{save_err.message}")
          end
        end
      ensure
        Thread.current[:topology_skip_overlap_check] = nil
      end
      raise ActiveRecord::Rollback if errors.any?
    end

    if errors.any?
      render json: { ok: false, errors: errors }, status: :unprocessable_entity
    else
      render json: {
        ok:             true,
        redirect:       "/lands/#{new_land_id}",
        land_id:        new_land_id,
        affected_count: computed_neighbors.length
      }
    end
  rescue => e
    Rails.logger.error("save_drum exception: #{e.class}: #{e.message}\n#{e.backtrace.first(10).join("\n")}")
    render json: { ok: false, errors: ["Eroare server: #{e.message}"] }, status: :unprocessable_entity
  end

  private

  # Normalizează snap_dist (default 5m, clamp [0.5..20] m).
  def sanitize_snap_dist(raw)
    v = raw.to_f
    v = 5.0 if v <= 0
    [[v, 0.5].max, 20.0].min
  end

  # Audit post-cleanup: recitește din BD aria salvată pentru fiecare poligon
  # modificat și verifică invariantul FLOOR(saved) == FLOOR(original).
  #
  # Rolul: detectează drift între ce promite algoritmul SQL (computed new_area
  # din pre-save SELECT) și ce ajunge efectiv în BD prin compute_derived al
  # modelului. Aceste două ar trebui să fie identice (ambele calculate de
  # PostGIS pe aceeași geometrie), dar audit-ul prinde anomalii: corupere
  # date, bug în compute_derived, divergență ST_Area, race conditions.
  #
  # Input:  modified — array de hash-uri cu {kind, entity_id, label, area_cad}
  # Output: hash cu {checked, passed, failed, failures, total_area_*}
  def audit_cleanup_areas(modified)
    return blank_audit if modified.empty?

    # Batch fetch suprafata_mp pentru toate poligoanele salvate (1 query/kind).
    saved_areas = {}
    parcele = modified.select { |m| m[:kind] == "parcela" }
    cladiri = modified.select { |m| m[:kind] == "cladire" }

    if parcele.any?
      GisLandGeometry.where(land_id: parcele.map { |m| m[:entity_id] })
                     .pluck(:land_id, :suprafata_mp).each do |id, area|
        saved_areas[["parcela", id]] = area.to_f
      end
    end
    if cladiri.any?
      GisBuildingGeometry.where(building_id: cladiri.map { |m| m[:entity_id] })
                         .pluck(:building_id, :suprafata_mp).each do |id, area|
        saved_areas[["cladire", id]] = area.to_f
      end
    end

    failures  = []
    total_old = 0.0
    total_new = 0.0

    modified.each do |m|
      total_old += m[:old_area].to_f
      key = [m[:kind], m[:entity_id]]
      saved = saved_areas[key]

      if saved.nil?
        failures << {
          kind: m[:kind], entity_id: m[:entity_id], label: m[:label],
          reason: "rândul gis_*_geometry lipsește post-save (find_by NULL)"
        }
        next
      end

      total_new += saved
      saved_floor = saved.floor
      expected    = m[:area_cad].to_i

      if saved_floor != expected
        failures << {
          kind: m[:kind], entity_id: m[:entity_id], label: m[:label],
          saved_area:     saved.round(4),
          saved_floor:    saved_floor,
          expected_floor: expected,
          delta_vs_promised: (saved - m[:new_area].to_f).round(4),
          reason: "aria în BD (FLOOR=#{saved_floor}) ≠ așteptat (FLOOR=#{expected}) — algoritmul a promis conservarea, BD spune altceva"
        }
      end
    end

    {
      checked:          modified.length,
      passed:           modified.length - failures.length,
      failed:           failures.length,
      failures:         failures,
      total_area_old:   total_old.round(4),
      total_area_new:   total_new.round(4),
      total_area_delta: (total_new - total_old).round(4)
    }
  end

  def blank_audit
    { checked: 0, passed: 0, failed: 0, failures: [],
      total_area_old: 0.0, total_area_new: 0.0, total_area_delta: 0.0 }
  end

  # Calculează banda drumului + lista vecinilor afectați (parcele + clădiri).
  # Apelat de buffer_drum (preview UI) ȘI save_drum (persistare) — clientul NU
  # trimite niciodată geometrie de drum, o calculăm pe server din axă +
  # parametri. Garantează că geometria salvată corespunde EXACT celei
  # previzualizate, prevenind injectarea de poligoane arbitrare în request.
  # Returns: { band: {wkt, geojson, area_mp, nverts}, neighbors: [...] } sau
  # nil dacă banda nu poate fi construită (axă invalidă, buffer eșuat).
  def compute_drum_geometry(line_wkt, width_m, snap_dist_m)
    # 1) Banda uniformă cu AXIS AUGMENTATION:
    # Adăugăm vertecși pe axă la proiecțiile vertecșilor poligoanelor vecine
    # → bufferul rezultat are vertecși corespunzători pe limită → polygons
    # se aliniază natural fără gap-uri.
    band_sql = ApplicationRecord.sanitize_sql_array([
      <<~SQL,
        WITH initial_axis AS (SELECT ST_GeomFromText(?, 3844) AS geom),
             initial_band AS (
               SELECT ST_Buffer((SELECT geom FROM initial_axis), ?, 'endcap=flat join=mitre quad_segs=4') AS geom
             ),
             candidate_vertices AS (
               SELECT (ST_DumpPoints(g.geom)).geom AS pt
               FROM   gis_land_geometries g
               JOIN   lands l ON l.id = g.land_id
               WHERE  ST_DWithin(g.geom, (SELECT geom FROM initial_band), ?)
                 AND  NOT EXISTS (
                   SELECT 1 FROM parcels p
                   WHERE p.land_id = l.id AND p.usecategory = 'DR'
                 )
               UNION ALL
               SELECT (ST_DumpPoints(g.geom)).geom AS pt
               FROM   gis_building_geometries g
               WHERE  ST_DWithin(g.geom, (SELECT geom FROM initial_band), ?)
             ),
             projections_on_axis AS (
               -- Proiecția perpendiculară a fiecărui vertex pe axă + poziția 0..1
               -- pe axă. Filtru: poziția pe axă în [0, 1] (nu extensia după capete).
               SELECT ST_ClosestPoint((SELECT geom FROM initial_axis), cv.pt) AS proj_pt,
                      ST_LineLocatePoint((SELECT geom FROM initial_axis), cv.pt) AS pos
               FROM   candidate_vertices cv
               WHERE  ST_LineLocatePoint((SELECT geom FROM initial_axis), cv.pt) > 0
                 AND  ST_LineLocatePoint((SELECT geom FROM initial_axis), cv.pt) < 1
             ),
             orig_axis_vertices AS (
               -- Vertecșii originali ai axei + pozițiile lor (0 → 1).
               SELECT ST_LineLocatePoint(ia.geom, dp.geom) AS pos,
                      dp.geom AS pt
               FROM   initial_axis ia,
                      LATERAL ST_DumpPoints(ia.geom) AS dp
             ),
             all_axis_points AS (
               SELECT pos, pt FROM orig_axis_vertices
               UNION ALL
               SELECT pos, proj_pt AS pt FROM projections_on_axis
             ),
             axis_augmented AS (
               -- Reconstruiește axa cu TOATE punctele ordonate după poziție.
               -- Vertecșii originali rămân pe loc; proiecțiile se INTERCALEAZĂ.
               SELECT ST_MakeLine(pt ORDER BY pos) AS geom FROM all_axis_points
             ),
             buf AS (
               SELECT ST_Buffer((SELECT geom FROM axis_augmented), ?, 'endcap=flat join=mitre quad_segs=4') AS geom
             )
        SELECT ST_AsText(geom)                AS wkt,
               ST_AsGeoJSON(geom, 6)          AS geojson,
               ROUND(ST_Area(geom)::numeric, 4) AS area_mp,
               ST_NPoints(geom)               AS nverts
        FROM   buf
      SQL
      line_wkt, width_m / 2.0, snap_dist_m, snap_dist_m, width_m / 2.0
    ])
    band_row = ActiveRecord::Base.connection.select_one(band_sql)
    return nil if band_row.nil? || band_row["wkt"].blank?

    band = {
      wkt:     band_row["wkt"],
      geojson: JSON.parse(band_row["geojson"]),
      area_mp: band_row["area_mp"].to_f,
      nverts:  band_row["nverts"].to_i
    }

    # 2) Vecinii afectați — algoritm 2-faze (translatare la contact + snap pe
    # muchia drumului) + similarity transform pentru păstrarea suprafeței.
    # Vezi documentația inline a SQL pentru detalii algoritm.
    detect_tolerance = snap_dist_m
    neighbors = []
    [
      ["parcela", parcele_geom_join],
      ["cladire", cladiri_geom_join]
    ].each do |kind, join_sql|
      n_sql = ApplicationRecord.sanitize_sql_array([
        <<~SQL,
          WITH axis AS (SELECT ST_GeomFromText(?, 3844) AS geom),
               band AS (SELECT ST_MakeValid(ST_GeomFromText(?, 3844)) AS geom),
               band_dense AS (
                 SELECT ST_MakeValid(ST_Segmentize((SELECT geom FROM band), 1.0)) AS geom
               ),
               band_segmented AS (
                 SELECT ST_MakeValid(ST_Segmentize((SELECT geom FROM band), ?)) AS geom
               ),
               axis_pts AS (
                 SELECT ST_X(ST_StartPoint((SELECT geom FROM axis))) AS x1,
                        ST_Y(ST_StartPoint((SELECT geom FROM axis))) AS y1,
                        ST_X(ST_EndPoint((SELECT geom FROM axis)))   AS x2,
                        ST_Y(ST_EndPoint((SELECT geom FROM axis)))   AS y2
               ),
               existing_roads AS (
                 -- Drumuri existente (Lands cu parcels.usecategory='DR').
                 SELECT g.geom
                 FROM   gis_land_geometries g
                 JOIN   parcels p ON p.land_id = g.land_id
                 WHERE  p.usecategory = 'DR' AND ST_IsValid(g.geom)
               ),
               candidates AS (
                 SELECT t.entity_id, ST_MakeValid(t.geom) AS old_geom,
                        ST_Intersects(t.geom, (SELECT geom FROM band)) AS overlapping,
                        -- has_anchor = polygonul atinge un drum EXISTENT (creat anterior)
                        COALESCE((
                          SELECT TRUE FROM existing_roads er
                          WHERE  ST_Touches(t.geom, er.geom)
                          LIMIT  1
                        ), FALSE) AS has_anchor
                 FROM   (#{join_sql}) t
                 WHERE  t.entity_id IS NOT NULL
                   AND  ST_DWithin(t.geom, (SELECT geom FROM band), ?)
                   AND  NOT EXISTS (
                          SELECT 1 FROM parcels p
                          WHERE  p.land_id = t.entity_id AND p.usecategory = 'DR'
                        )
               ),
               non_affected_union AS (
                 SELECT ST_Union(ST_MakeValid(t.geom)) AS geom
                 FROM   (#{join_sql}) t
                 WHERE  t.entity_id IS NOT NULL
                   AND  ST_DWithin(t.geom, (SELECT geom FROM band), 50.0)
                   AND  NOT EXISTS (
                          SELECT 1 FROM candidates c WHERE c.entity_id = t.entity_id
                        )
               ),
               sided AS (
                 SELECT c.entity_id, c.old_geom, c.overlapping,
                        CASE
                          WHEN ((ap.x2 - ap.x1) * (ST_Y(ST_Centroid(c.old_geom)) - ap.y1)
                              - (ap.y2 - ap.y1) * (ST_X(ST_Centroid(c.old_geom)) - ap.x1)) > 0
                          THEN 'L' ELSE 'R'
                        END AS side
                 FROM   candidates c
                 CROSS  JOIN axis_pts ap
               ),
               clustered AS (
                 SELECT entity_id, old_geom, overlapping, side,
                        ST_ClusterDBSCAN(old_geom, eps := 0.5, minpoints := 1)
                          OVER (PARTITION BY side) AS cluster_id
                 FROM   sided
               ),
               cluster_metrics AS (
                 SELECT side, cluster_id,
                        ST_Union(old_geom)                                          AS combined,
                        BOOL_OR(overlapping)                                        AS has_overlap,
                        ST_Centroid(ST_Union(old_geom))                             AS cpt,
                        ST_ClosestPoint((SELECT geom FROM axis), ST_Centroid(ST_Union(old_geom))) AS apt,
                        COUNT(*)                                                    AS member_count
                 FROM   clustered
                 GROUP  BY side, cluster_id
               ),
               cluster_translation AS (
                 SELECT side, cluster_id, member_count, has_overlap,
                        ST_X(ST_EndPoint(ST_ShortestLine(combined, (SELECT geom FROM band))))
                        - ST_X(ST_StartPoint(ST_ShortestLine(combined, (SELECT geom FROM band)))) AS dx_raw,
                        ST_Y(ST_EndPoint(ST_ShortestLine(combined, (SELECT geom FROM band))))
                        - ST_Y(ST_StartPoint(ST_ShortestLine(combined, (SELECT geom FROM band)))) AS dy_raw,
                        sqrt(POWER(ST_X(cpt) - ST_X(apt), 2) + POWER(ST_Y(cpt) - ST_Y(apt), 2)) AS d_axis,
                        ? AS halfw
                 FROM   cluster_metrics
               ),
               translated AS (
                 -- has_anchor: polygon e deja alipit de drum existent → NU translatare.
                 -- Doar overlap aplică Difference (taie partea din drum nou).
                 SELECT c.entity_id, c.old_geom, ct.member_count, c.overlapping,
                        CASE
                          WHEN c.overlapping THEN
                            ST_Multi(ST_MakeValid(ST_Difference(c.old_geom, (SELECT geom FROM band))))
                          WHEN ca.has_anchor THEN
                            c.old_geom  -- nu translata polygon anchored la drum existent
                          WHEN ct.has_overlap THEN
                            ST_MakeValid(ST_Translate(c.old_geom,
                              ST_X(ST_EndPoint(ST_ShortestLine(c.old_geom, (SELECT geom FROM band))))
                              - ST_X(ST_StartPoint(ST_ShortestLine(c.old_geom, (SELECT geom FROM band)))),
                              ST_Y(ST_EndPoint(ST_ShortestLine(c.old_geom, (SELECT geom FROM band))))
                              - ST_Y(ST_StartPoint(ST_ShortestLine(c.old_geom, (SELECT geom FROM band))))
                            ))
                          WHEN ct.d_axis < 0.01 THEN c.old_geom
                          ELSE
                            ST_MakeValid(ST_Translate(c.old_geom, ct.dx_raw, ct.dy_raw))
                        END AS t_geom
                 FROM   clustered c
                 JOIN   cluster_translation ct ON ct.side = c.side AND ct.cluster_id = c.cluster_id
                 JOIN   candidates ca ON ca.entity_id = c.entity_id
               ),
               polygon_points_ordered AS (
                 SELECT t.entity_id, t.old_geom, t.member_count, t.overlapping, t.t_geom,
                        (dp.path)[1] AS poly_idx,
                        (dp.path)[2] AS ring_idx,
                        (dp.path)[3] AS pt_idx,
                        dp.geom AS orig_pt
                 FROM   translated t,
                        LATERAL ST_DumpPoints(t.t_geom) AS dp
               ),
               segments_with_dist AS (
                 SELECT a.entity_id, a.poly_idx, a.ring_idx,
                        a.pt_idx AS pt1_idx, b.pt_idx AS pt2_idx,
                        ST_Distance(ST_MakeLine(a.orig_pt, b.orig_pt), (SELECT geom FROM band)) AS seg_dist
                 FROM   polygon_points_ordered a
                 JOIN   polygon_points_ordered b
                   ON   a.entity_id = b.entity_id
                  AND   a.poly_idx = b.poly_idx
                  AND   a.ring_idx = b.ring_idx
                  AND   b.pt_idx = a.pt_idx + 1
                 WHERE  NOT a.overlapping
               ),
               closest_segment AS (
                 SELECT entity_id, poly_idx, ring_idx, pt1_idx, pt2_idx,
                        ROW_NUMBER() OVER (PARTITION BY entity_id ORDER BY seg_dist ASC) AS rank
                 FROM   segments_with_dist
               ),
               project_targets AS (
                 SELECT entity_id, poly_idx, ring_idx, pt1_idx AS pt_idx
                 FROM   closest_segment WHERE rank = 1
                 UNION  ALL
                 SELECT entity_id, poly_idx, ring_idx, pt2_idx AS pt_idx
                 FROM   closest_segment WHERE rank = 1
               ),
               gap_endpoints AS (
                 SELECT cs.entity_id,
                        a.orig_pt AS old_A, b.orig_pt AS old_B,
                        ST_ClosestPoint(ST_Boundary((SELECT geom FROM band)), a.orig_pt) AS new_A,
                        ST_ClosestPoint(ST_Boundary((SELECT geom FROM band)), b.orig_pt) AS new_B
                 FROM   closest_segment cs
                 JOIN   polygon_points_ordered a
                   ON   cs.entity_id = a.entity_id AND cs.poly_idx = a.poly_idx
                  AND   cs.ring_idx = a.ring_idx AND cs.pt1_idx = a.pt_idx
                 JOIN   polygon_points_ordered b
                   ON   cs.entity_id = b.entity_id AND cs.poly_idx = b.poly_idx
                  AND   cs.ring_idx = b.ring_idx AND cs.pt2_idx = b.pt_idx
                 WHERE  cs.rank = 1
               ),
               gap_similarity_matrix AS (
                 SELECT ge.entity_id, ge.old_A, ge.old_B, ge.new_A, ge.new_B,
                        ((ST_X(ge.old_B) - ST_X(ge.old_A)) * (ST_X(ge.new_B) - ST_X(ge.new_A)) +
                         (ST_Y(ge.old_B) - ST_Y(ge.old_A)) * (ST_Y(ge.new_B) - ST_Y(ge.new_A))) /
                        NULLIF(POWER(ST_X(ge.old_B) - ST_X(ge.old_A), 2) +
                               POWER(ST_Y(ge.old_B) - ST_Y(ge.old_A), 2), 0) AS cc,
                        ((ST_X(ge.old_B) - ST_X(ge.old_A)) * (ST_Y(ge.new_B) - ST_Y(ge.new_A)) -
                         (ST_Y(ge.old_B) - ST_Y(ge.old_A)) * (ST_X(ge.new_B) - ST_X(ge.new_A))) /
                        NULLIF(POWER(ST_X(ge.old_B) - ST_X(ge.old_A), 2) +
                               POWER(ST_Y(ge.old_B) - ST_Y(ge.old_A), 2), 0) AS ss,
                        sqrt(POWER(ST_X(ge.old_B) - ST_X(ge.old_A), 2) +
                             POWER(ST_Y(ge.old_B) - ST_Y(ge.old_A), 2)) AS old_len,
                        sqrt(POWER(ST_X(ge.new_B) - ST_X(ge.new_A), 2) +
                             POWER(ST_Y(ge.new_B) - ST_Y(ge.new_A), 2)) AS new_len
                 FROM   gap_endpoints ge
               ),
               gap_full_matrix AS (
                 -- Skip polygons cu has_anchor (deja alipite de drum existent).
                 SELECT m.entity_id,
                        m.old_A, m.new_A, m.cc, m.ss,
                        (ST_X(m.new_B) - ST_X(m.new_A)) / NULLIF(m.new_len, 0) AS ux,
                        (ST_Y(m.new_B) - ST_Y(m.new_A)) / NULLIF(m.new_len, 0) AS uy,
                        m.new_len / NULLIF(m.old_len, 0) AS k
                 FROM   gap_similarity_matrix m
                 JOIN   candidates c ON c.entity_id = m.entity_id
                 WHERE  m.old_len > 0.01 AND m.new_len > 0.01
                   AND  m.new_len / m.old_len BETWEEN 0.7 AND 1.5
                   AND  NOT c.has_anchor
               ),
               polygon_points_similarity AS (
                 SELECT p.entity_id, p.old_geom, p.member_count, p.overlapping, p.t_geom,
                        p.poly_idx, p.ring_idx, p.pt_idx, p.orig_pt,
                        m.new_A, m.ux, m.uy, m.k,
                        CASE
                          WHEN NOT p.overlapping AND m.entity_id IS NOT NULL THEN
                            ST_MakePoint(
                              m.cc * ST_X(p.orig_pt) - m.ss * ST_Y(p.orig_pt)
                                + ST_X(m.new_A) - m.cc * ST_X(m.old_A) + m.ss * ST_Y(m.old_A),
                              m.ss * ST_X(p.orig_pt) + m.cc * ST_Y(p.orig_pt)
                                + ST_Y(m.new_A) - m.ss * ST_X(m.old_A) - m.cc * ST_Y(m.old_A)
                            )
                          ELSE p.orig_pt
                        END AS pt_similarity
                 FROM   polygon_points_ordered p
                 LEFT   JOIN gap_full_matrix m ON m.entity_id = p.entity_id
               ),
               polygon_rings AS (
                 -- 3 cazuri:
                 --   1. Non-anchor + similarity matrix valid: perp scale (suprafață exactă)
                 --   2. Anchor + endpoint pe closest segment: per-edge projection
                 --      (vertecșii anchored la drum vechi NU se mișcă; doar
                 --      endpoint-urile muchiei spre drumul nou se proiectează)
                 --   3. Restul: orig_pt (no change)
                 SELECT ps.entity_id, ps.old_geom, ps.member_count, ps.overlapping, ps.t_geom,
                        ARRAY[ps.poly_idx, ps.ring_idx, ps.pt_idx] AS path,
                        CASE
                          WHEN NOT ps.overlapping AND ps.new_A IS NOT NULL THEN
                            -- Caz 1: similarity + perp scaling (non-anchor, k în range)
                            ST_SetSRID(ST_MakePoint(
                              (ps.ux*ps.ux + ps.uy*ps.uy/(ps.k*ps.k)) * (ST_X(ps.pt_similarity) - ST_X(ps.new_A))
                              + (ps.ux*ps.uy*(1 - 1/(ps.k*ps.k))) * (ST_Y(ps.pt_similarity) - ST_Y(ps.new_A))
                              + ST_X(ps.new_A),
                              (ps.ux*ps.uy*(1 - 1/(ps.k*ps.k))) * (ST_X(ps.pt_similarity) - ST_X(ps.new_A))
                              + (ps.uy*ps.uy + ps.ux*ps.ux/(ps.k*ps.k)) * (ST_Y(ps.pt_similarity) - ST_Y(ps.new_A))
                              + ST_Y(ps.new_A)
                            ), 3844)
                          WHEN NOT ps.overlapping
                           AND (pt.entity_id IS NOT NULL
                                OR ST_DWithin(ps.orig_pt, (SELECT geom FROM band), ?))
                          THEN
                            -- Caz 2: per-vertex projection — pentru anchored polygons
                            -- ȘI pentru polygons unde similarity nu s-a aplicat.
                            -- Acum proiectează ORICE vertex în limita pragului față
                            -- de drum (nu doar endpoint-urile closest_segment).
                            ST_ClosestPoint(ST_Boundary((SELECT geom FROM band)), ps.orig_pt)
                          ELSE ps.pt_similarity
                        END AS pt
                 FROM   polygon_points_similarity ps
                 LEFT   JOIN candidates ca ON ca.entity_id = ps.entity_id
                 LEFT   JOIN project_targets pt
                   ON   pt.entity_id = ps.entity_id
                  AND   pt.poly_idx = ps.poly_idx
                  AND   pt.ring_idx = ps.ring_idx
                  AND   pt.pt_idx = ps.pt_idx
               ),
               rings_built AS (
                 SELECT entity_id, old_geom, member_count, overlapping, t_geom,
                        path[1] AS poly_idx, path[2] AS ring_idx,
                        ST_MakeLine(pt ORDER BY path[3]) AS ring_line
                 FROM   polygon_rings
                 GROUP  BY entity_id, old_geom, member_count, overlapping, t_geom, path[1], path[2]
               ),
               base_geom_raw AS (
                 SELECT entity_id, old_geom, member_count, overlapping,
                        CASE
                          WHEN overlapping THEN ST_Union(t_geom)
                          ELSE ST_MakeValid(ST_Multi(ST_BuildArea(ST_Collect(ring_line))))
                        END AS b_geom,
                        ST_Union(t_geom) AS t_geom_fallback
                 FROM   rings_built
                 GROUP  BY entity_id, old_geom, member_count, overlapping
               ),
               base_geom AS (
                 SELECT entity_id, old_geom, member_count, overlapping,
                        ST_Multi(ST_MakeValid(ST_Difference(
                          ST_Difference(
                            CASE
                              WHEN b_geom IS NOT NULL AND ST_IsValid(b_geom) AND NOT ST_IsEmpty(b_geom)
                              THEN b_geom
                              ELSE t_geom_fallback
                            END,
                            (SELECT geom FROM band)
                          ),
                          COALESCE((SELECT geom FROM non_affected_union),
                                   ST_GeomFromText('POLYGON EMPTY', 3844))
                        ))) AS b_geom
                 FROM   base_geom_raw
               ),
               cluster_overlap_others AS (
                 SELECT c.entity_id, ct.side, ct.cluster_id,
                        ST_Union(b.b_geom) AS others_geom
                 FROM   clustered c
                 JOIN   cluster_translation ct ON ct.side = c.side AND ct.cluster_id = c.cluster_id
                 JOIN   base_geom b ON b.entity_id != c.entity_id
                                   AND EXISTS (
                                     SELECT 1 FROM clustered c2
                                     WHERE c2.entity_id = b.entity_id
                                       AND c2.side = c.side
                                       AND c2.cluster_id = c.cluster_id
                                       AND c2.overlapping
                                   )
                 GROUP BY c.entity_id, ct.side, ct.cluster_id
               ),
               overlap_pieces AS (
                 SELECT b.entity_id, b.old_geom, b.member_count,
                        (dp).geom AS piece,
                        ROW_NUMBER() OVER (PARTITION BY b.entity_id ORDER BY ST_Area((dp).geom) DESC) AS rank,
                        SUM(ST_Area((dp).geom)) OVER (PARTITION BY b.entity_id) AS total_diff_area
                 FROM   base_geom b,
                        LATERAL ST_Dump(b.b_geom) AS dp
                 WHERE  b.overlapping
                   AND  ST_IsValid(b.b_geom)
                   AND  NOT ST_IsEmpty(b.b_geom)
               ),
               overlap_expanded AS (
                 SELECT op.entity_id, op.old_geom, op.member_count,
                        ST_MakeValid(ST_Difference(
                          ST_Buffer(op.piece,
                            LEAST(
                              (ST_Area(op.old_geom) - ST_Area(op.piece)) / NULLIF(ST_Perimeter(op.piece), 0),
                              GREATEST(ct.halfw - 0.5, 0.1)
                            ),
                            'join=mitre mitre_limit=5.0 quad_segs=2'),
                          (SELECT geom FROM band)
                        )) AS new_piece
                 FROM   overlap_pieces op
                 JOIN   clustered c ON c.entity_id = op.entity_id
                 JOIN   cluster_translation ct ON ct.side = c.side AND ct.cluster_id = c.cluster_id
                 WHERE  op.rank = 1
                   AND  ST_Area(op.piece) > 0.01
                   AND  ST_Perimeter(op.piece) > 0.5
                   AND  ST_Area(op.old_geom) > ST_Area(op.piece) + 0.05
               ),
               overlap_grouped AS (
                 SELECT entity_id, old_geom, member_count,
                        ST_Multi(ST_MakeValid(ST_Union(new_piece))) AS new_geom
                 FROM   overlap_expanded
                 GROUP  BY entity_id, old_geom, member_count
               ),
               overlap_unified AS (
                 -- Fine-tuning area: dacă buffer compensation nu a recuperat arie
                 -- exactă (diferență 0.05–5%), aplică scalare uniformă din centroid
                 -- → aria EXACT egală cu old_area. Deplasare vertecși proporțională
                 -- (pentru 0.1% diferență, ~2-3cm — neglijabil vizual).
                 SELECT entity_id, old_geom, member_count,
                        CASE
                          WHEN ST_Area(new_geom) > 0.01
                           AND ABS(ST_Area(new_geom) - ST_Area(old_geom)) > 0.05
                           AND ST_Area(new_geom) BETWEEN ST_Area(old_geom) * 0.95 AND ST_Area(old_geom) * 1.05
                          THEN ST_Multi(ST_MakeValid(ST_Affine(new_geom,
                            sqrt(ST_Area(old_geom) / NULLIF(ST_Area(new_geom), 0)),
                            0, 0,
                            sqrt(ST_Area(old_geom) / NULLIF(ST_Area(new_geom), 0)),
                            (1 - sqrt(ST_Area(old_geom) / NULLIF(ST_Area(new_geom), 0))) * ST_X(ST_Centroid(new_geom)),
                            (1 - sqrt(ST_Area(old_geom) / NULLIF(ST_Area(new_geom), 0))) * ST_Y(ST_Centroid(new_geom))
                          )))
                          ELSE new_geom
                        END AS new_geom,
                        TRUE AS overlapping
                 FROM   overlap_grouped
               ),
               final_geom AS (
                 SELECT b.entity_id, b.old_geom, b.member_count,
                        COALESCE(ou.new_geom, b.b_geom) AS new_geom
                 FROM   base_geom b
                 LEFT   JOIN overlap_unified ou ON ou.entity_id = b.entity_id
               )
          SELECT entity_id,
                 ST_AsText(ST_Multi(new_geom))                 AS new_wkt,
                 ST_AsGeoJSON(ST_Multi(new_geom), 6)           AS new_geojson,
                 ROUND(ST_Area(old_geom)::numeric, 4)          AS old_area,
                 ROUND(ST_Area(new_geom)::numeric, 4)          AS new_area,
                 ROUND((ST_Area(new_geom) - ST_Area(old_geom))::numeric, 4) AS area_delta,
                 ST_IsValid(new_geom)                          AS valid_new,
                 ST_IsEmpty(new_geom)                          AS empty_new,
                 CASE WHEN member_count > 1 THEN 'grup translatat' ELSE 'translatat' END AS reason
          FROM   final_geom
          WHERE  ST_IsValid(new_geom) AND NOT ST_IsEmpty(new_geom)
        SQL
        line_wkt, band[:wkt], detect_tolerance, detect_tolerance, width_m / 2.0, detect_tolerance
      ])
      ActiveRecord::Base.connection.select_all(n_sql).to_a.each do |r|
        eid = r["entity_id"].to_i
        next if eid <= 0
        if r["empty_new"] || !r["valid_new"]
          neighbors << {
            kind: kind, entity_id: eid, new_wkt: nil, new_geojson: nil, delete: true,
            old_area: r["old_area"].to_f, new_area: 0.0,
            area_delta: -r["old_area"].to_f, reason: "acoperit integral"
          }
          next
        end
        neighbors << {
          kind:        kind,
          entity_id:   eid,
          new_wkt:     r["new_wkt"],
          new_geojson: JSON.parse(r["new_geojson"]),
          delete:      false,
          old_area:    r["old_area"].to_f,
          new_area:    r["new_area"].to_f,
          area_delta:  r["area_delta"].to_f,
          reason:      "alipit la drum, suprafață compensată"
        }
      end
    end

    { band: band, neighbors: neighbors }
  end

  # ── Subqueries reutilizabile pentru parcele/clădiri drafturi (Lands/Buildings) ──
  # Returnează (gis_id, land_id|building_id, label, geom). Filtrul status='draft'
  # ține ascuns lands-urile cgxml care eventual au gis_geometry de tip 'active'.
  # `entity_id` = land_id / building_id — folosit pentru filtrarea exclusion-urilor
  # (clientul trimite editIdValue = feature.id = land.id, nu gis_geom.id).
  # UNION include CGXML lands/buildings fără cache `gis_*_geometries`, cu
  # geometrie reconstruită din `points` — astfel topology check + capture_overlap_set
  # văd toate poligoanele cadastrale, nu doar pe cele cached.
  def parcele_geom_join
    <<~SQL.strip
      SELECT g.id AS gis_id, g.land_id AS entity_id,
             COALESCE(l.cadgenno, 'L#' || l.id) AS label, g.geom
      FROM gis_land_geometries g
      JOIN lands l ON l.id = g.land_id
      UNION ALL
      SELECT NULL::bigint AS gis_id, ll.land_id AS entity_id,
             COALESCE(l.cadgenno, 'L#' || l.id) AS label,
             CASE WHEN ST_IsClosed(ll.line)
                  THEN ST_MakePolygon(ll.line)
                  ELSE ST_MakePolygon(ST_AddPoint(ll.line, ST_StartPoint(ll.line)))
             END AS geom
      FROM (
        SELECT land_id, ST_MakeLine(coordinates ORDER BY no) AS line
        FROM   points
        WHERE  land_id IS NOT NULL AND coordinates IS NOT NULL
          AND  NOT EXISTS (SELECT 1 FROM gis_land_geometries gg WHERE gg.land_id = points.land_id)
        GROUP  BY land_id
        HAVING COUNT(*) >= 3
      ) ll
      JOIN lands l ON l.id = ll.land_id
      WHERE ST_IsValid(
        CASE WHEN ST_IsClosed(ll.line)
             THEN ST_MakePolygon(ll.line)
             ELSE ST_MakePolygon(ST_AddPoint(ll.line, ST_StartPoint(ll.line)))
        END
      )
    SQL
  end

  def cladiri_geom_join
    <<~SQL.strip
      SELECT g.id AS gis_id, g.building_id AS entity_id,
             COALESCE(b.cadgenno, 'B#' || b.id) AS label, g.geom
      FROM gis_building_geometries g
      JOIN buildings b ON b.id = g.building_id
      UNION ALL
      SELECT NULL::bigint AS gis_id, bl.building_id AS entity_id,
             COALESCE(b.cadgenno, 'B#' || b.id) AS label,
             CASE WHEN ST_IsClosed(bl.line)
                  THEN ST_MakePolygon(bl.line)
                  ELSE ST_MakePolygon(ST_AddPoint(bl.line, ST_StartPoint(bl.line)))
             END AS geom
      FROM (
        SELECT building_id, ST_MakeLine(coordinates ORDER BY no) AS line
        FROM   points
        WHERE  building_id IS NOT NULL AND coordinates IS NOT NULL
          AND  NOT EXISTS (SELECT 1 FROM gis_building_geometries gg WHERE gg.building_id = points.building_id)
        GROUP  BY building_id
        HAVING COUNT(*) >= 3
      ) bl
      JOIN buildings b ON b.id = bl.building_id
      WHERE ST_IsValid(
        CASE WHEN ST_IsClosed(bl.line)
             THEN ST_MakePolygon(bl.line)
             ELSE ST_MakePolygon(ST_AddPoint(bl.line, ST_StartPoint(bl.line)))
        END
      )
    SQL
  end

  # Creează un Land draft + GisLandGeometry. Returnează [land, error_message].
  def create_land_draft(cadgenno:, geom_wkt:, usecategory: nil)
    land = Land.new(
      cadgenno: cadgenno,
      measuredarea: 0,
      isnew: true,
      notes: usecategory ? "Categorie folosință: #{usecategory}" : nil
    )
    if land.save
      g = land.build_gis_geometry(status: "draft", geom_wkt: geom_wkt)
      if g.save
        # parcels child cu usecategory (pentru consistență cu modelul cgxml)
        if usecategory.present?
          Parcel.create!(land_id: land.id, usecategory: usecategory, number: 1)
        end
        [land, nil]
      else
        land.destroy
        [nil, g.errors.full_messages.first]
      end
    else
      [nil, land.errors.full_messages.first]
    end
  rescue => e
    [nil, e.message]
  end

  # Creează un Building draft + GisBuildingGeometry. Caută parcela părinte
  # via spatial query înainte de save (Building.land_id e NOT NULL la nivel DB).
  def create_building_draft(cadgenno:, geom_wkt:)
    land_id = find_parent_land_id(geom_wkt)
    return [nil, "nu există parcelă digitizată care să conțină clădirea"] unless land_id

    bld = Building.new(
      cadgenno: cadgenno,
      buildno: next_buildno_for_draft,
      islegal: false,
      measuredarea: 0,
      land_id: land_id
    )
    bld.save(validate: false)
    g = bld.build_gis_geometry(status: "draft", geom_wkt: geom_wkt)
    if g.save
      [bld, nil]
    else
      bld.destroy
      [nil, g.errors.full_messages.first]
    end
  rescue => e
    [nil, e.message]
  end

  def find_parent_land_id(geom_wkt)
    ApplicationRecord.connection.select_value(
      ApplicationRecord.sanitize_sql_array([<<~SQL, geom_wkt, geom_wkt])
        SELECT g.land_id
        FROM gis_land_geometries g
        WHERE ST_Intersects(g.geom, ST_GeomFromText(?, 3844))
        ORDER BY ST_Area(ST_Intersection(g.geom, ST_GeomFromText(?, 3844))) DESC
        LIMIT 1
      SQL
    )
  end

  def next_buildno_for_draft
    (Building.maximum(:buildno) || 0) + 1
  end

  # Faza 1 a save_batch — aplică payload, save fără validări.
  def phase1_save_record(record, payload, errors)
    kind = payload[:kind] || payload["kind"]
    wkt  = payload[:geom_wkt] || payload["geom_wkt"]
    area = payload[:suprafata_mp] || payload["suprafata_mp"]

    g = record.gis_geometry || record.build_gis_geometry(status: "draft")
    g.geom_wkt = wkt if wkt.present?
    g.suprafata_mp = area if area.present?

    unless g.save(validate: false)
      errors << "#{kind} #{record.label}: salvare DB eșuată (#{g.errors.full_messages.first})"
    end
  end

  # Capturează overlap-urile actuale ale unui record cu alte poligoane de același tip.
  def capture_overlap_set(record)
    g = record.gis_geometry
    return Set.new unless g&.geom

    join_sql = record.is_a?(Building) ? cladiri_geom_join : parcele_geom_join
    rows = record.class.connection.select_all(
      ApplicationRecord.sanitize_sql_array([<<~SQL, g.geom.as_text, record.id])
        WITH np AS (SELECT ST_GeomFromText(?, 3844) AS geom)
        SELECT t.entity_id AS id, t.label,
          ROUND(ST_Area(ST_Intersection(t.geom, np.geom))::numeric, 2) AS area
        FROM (#{join_sql}) t, np
        WHERE t.entity_id != ?
          AND ST_Intersects(t.geom, np.geom)
          AND ST_Area(ST_Intersection(t.geom, np.geom)) > 0.01
      SQL
    )
    rows.each_with_object(Set.new) { |r, s| s << [r["id"].to_i, r["label"], r["area"].to_f] }
  end

  # Colectează features (parcele + clădiri) care intersectează zona de export.
  def collect_features_in_zone(area_wkt, layers)
    features = []
    if layers.include?("parcele")
      ActiveRecord::Base.connection.select_all(
        ApplicationRecord.sanitize_sql_array([<<~SQL, area_wkt])
          SELECT 'parcela' AS kind, g.land_id AS id,
            COALESCE(l.cadgenno, 'L#' || l.id) AS label,
            (SELECT usecategory FROM parcels WHERE land_id = l.id LIMIT 1) AS category,
            ST_AsText(g.geom) AS wkt_3844,
            ST_AsKML(ST_Transform(g.geom, 4326), 6) AS kml_geom,
            ROUND(ST_Area(g.geom)::numeric)::int AS suprafata_mp,
            ST_X(ST_PointOnSurface(g.geom)) AS label_x,
            ST_Y(ST_PointOnSurface(g.geom)) AS label_y
          FROM gis_land_geometries g
          JOIN lands l ON l.id = g.land_id
          WHERE ST_Intersects(g.geom, ST_GeomFromText(?, 3844))
        SQL
      ).each { |r| features << r.symbolize_keys }
    end
    if layers.include?("cladiri")
      ActiveRecord::Base.connection.select_all(
        ApplicationRecord.sanitize_sql_array([<<~SQL, area_wkt])
          SELECT 'cladire' AS kind, g.building_id AS id,
            COALESCE(b.cadgenno, 'B#' || b.id) AS label,
            b.buildingdestination AS category,
            ST_AsText(g.geom) AS wkt_3844,
            ST_AsKML(ST_Transform(g.geom, 4326), 6) AS kml_geom,
            ROUND(ST_Area(g.geom)::numeric)::int AS suprafata_mp,
            ST_X(ST_PointOnSurface(g.geom)) AS label_x,
            ST_Y(ST_PointOnSurface(g.geom)) AS label_y
          FROM gis_building_geometries g
          JOIN buildings b ON b.id = g.building_id
          WHERE ST_Intersects(g.geom, ST_GeomFromText(?, 3844))
        SQL
      ).each { |r| features << r.symbolize_keys }
    end
    features
  end

  def build_dxf_multi(features)
    text_height = 1.0
    entities = features.map do |f|
      coords = parse_polygon_wkt(f[:wkt_3844])
      next nil if coords.empty?
      poly_layer = f[:kind] == "cladire" ? "CLADIRI"      : "PARCELE"
      text_layer = f[:kind] == "cladire" ? "CLADIRI_TEXT" : "PARCELE_TEXT"
      verts = coords.map { |x, y| "10\n#{format('%.4f', x)}\n20\n#{format('%.4f', y)}\n30\n0.0000" }.join("\n")

      poly_ent = <<~ENT
        0
        LWPOLYLINE
        8
        #{poly_layer}
        90
        #{coords.length}
        70
        1
        #{verts}
      ENT

      text_ents = ""
      lx, ly = f[:label_x], f[:label_y]
      if lx && ly
        label    = f[:label].to_s
        suprafata = "#{f[:suprafata_mp]} mp"
        text_ents = build_dxf_text(text_layer, lx, ly + text_height * 0.6, text_height, label) +
                    build_dxf_text(text_layer, lx, ly - text_height * 0.6, text_height * 0.8, suprafata)
      end

      poly_ent + text_ents
    end.compact.join("\n")

    <<~DXF
      0
      SECTION
      2
      HEADER
      9
      $ACADVER
      1
      AC1015
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
      4
      0
      LAYER
      2
      PARCELE
      70
      0
      62
      5
      6
      CONTINUOUS
      0
      LAYER
      2
      CLADIRI
      70
      0
      62
      1
      6
      CONTINUOUS
      0
      LAYER
      2
      PARCELE_TEXT
      70
      0
      62
      7
      6
      CONTINUOUS
      0
      LAYER
      2
      CLADIRI_TEXT
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
      #{entities}
      0
      ENDSEC
      0
      EOF
    DXF
  end

  def build_dxf_text(layer, x, y, height, text)
    safe = text.to_s.gsub(/[\r\n]/, " ").strip
    return "" if safe.empty?
    <<~ENT
      0
      TEXT
      8
      #{layer}
      10
      #{format('%.4f', x)}
      20
      #{format('%.4f', y)}
      30
      0.0000
      40
      #{format('%.4f', height)}
      1
      #{safe}
      72
      1
      11
      #{format('%.4f', x)}
      21
      #{format('%.4f', y)}
      31
      0.0000
    ENT
  end

  def build_kml(features)
    placemarks = features.map do |f|
      style    = f[:kind] == "cladire" ? "#cladireStyle" : "#parcelaStyle"
      label    = f[:label].presence || f[:id].to_s
      desc     = "#{f[:kind].capitalize} — #{f[:category]} — #{f[:suprafata_mp]} mp"
      <<~XML
        <Placemark>
          <name>#{ERB::Util.html_escape(label)}</name>
          <description>#{ERB::Util.html_escape(desc)}</description>
          <styleUrl>#{style}</styleUrl>
          <ExtendedData>
            <Data name="numar_cadastral"><value>#{ERB::Util.html_escape(label)}</value></Data>
            <Data name="kind"><value>#{f[:kind]}</value></Data>
            <Data name="category"><value>#{ERB::Util.html_escape(f[:category].to_s)}</value></Data>
            <Data name="suprafata_mp"><value>#{f[:suprafata_mp]}</value></Data>
          </ExtendedData>
          #{f[:kml_geom]}
        </Placemark>
      XML
    end.join

    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <kml xmlns="http://www.opengis.net/kml/2.2">
        <Document>
          <name>Export e-CAD #{Time.current.strftime('%Y-%m-%d %H:%M')}</name>
          <Style id="parcelaStyle">
            <LineStyle><color>ffd84e1d</color><width>2</width></LineStyle>
            <PolyStyle><color>553b82f6</color></PolyStyle>
          </Style>
          <Style id="cladireStyle">
            <LineStyle><color>ff0953b4</color><width>2</width></LineStyle>
            <PolyStyle><color>5524bffb</color></PolyStyle>
          </Style>
          #{placemarks}
        </Document>
      </kml>
    XML
  end

  def build_gpkg(features)
    require "tempfile"
    return nil unless system("which ogr2ogr > /dev/null 2>&1")

    kml_text = build_kml(features)
    tmp_kml = Tempfile.new(["export", ".kml"])
    tmp_gpkg_path = "#{tmp_kml.path}.gpkg"
    begin
      tmp_kml.write(kml_text)
      tmp_kml.close
      ok = system("ogr2ogr -f GPKG #{Shellwords.escape(tmp_gpkg_path)} #{Shellwords.escape(tmp_kml.path)}")
      return nil unless ok && File.exist?(tmp_gpkg_path)
      File.binread(tmp_gpkg_path)
    ensure
      tmp_kml.unlink
      File.delete(tmp_gpkg_path) if File.exist?(tmp_gpkg_path)
    end
  end

  def parse_polygon_wkt(wkt)
    return [] if wkt.blank?
    m = wkt.match(/\(\(([^()]+)\)\)/)
    return [] unless m
    m[1].split(",").map { |pt| pt.strip.split(/\s+/).first(2).map(&:to_f) }
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
