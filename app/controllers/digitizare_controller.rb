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
      issues << {
        type: "overlap", severity: "error", neighbor_kind: kind,
        neighbor_id: row["id"], neighbor_label: row["label"],
        area: row["area"].to_f.round(3),
        message: "Suprapunere cu #{kind} #{row['label']}: #{row['area'].to_f.round(2)} mp",
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
      issues << {
        type: "sliver", severity: "warning", neighbor_kind: "parcela",
        neighbor_id: row["neighbor_id"], neighbor_label: row["neighbor_label"],
        area: row["gap_area"].to_f,
        message: "Gap între tine și parcela #{row['neighbor_label']}: #{row['gap_area']} mp",
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

      # Faza 1: save fără overlap-check (geometriile simultan)
      Thread.current[:topology_skip_overlap_check] = true
      begin
        records_with_payloads.each do |record, payload|
          phase1_save_record(record, payload, errors)
        end
      ensure
        Thread.current[:topology_skip_overlap_check] = nil
      end
      raise ActiveRecord::Rollback if errors.any?

      # Faza 2: alte validări (topologic_valid, traverseaza_parcele)
      Thread.current[:topology_skip_overlap_check] = true
      begin
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

  private

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
