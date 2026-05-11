module Gis
  # Divizează o parcelă (poligon) în N sub-parcele cu suprafețe țintă date.
  # Mod 1 (parallel): linii perpendiculare pe axa principală a OMBR (oriented
  # minimum bounding rectangle), pozițiile calculate cumulativ după suprafață.
  class ParcelDivider
    SRID = 3844

    Result = Struct.new(:pieces, :diagnostics, :error, keyword_init: true) do
      def success? = error.nil?
    end

    # piece = { wkt:, area_calc:, area_target:, area_diff: }
    # diagnostics = { axis_length:, total_area:, target_sum:, area_ratio:, mode: }

    # Acceptă fie un model (`parcela:`) fie un WKT brut (`geom_wkt:`).
    # Conturul temporar de divizare folosește `geom_wkt:` direct.
    def self.call(target_areas:, parcela: nil, geom_wkt: nil, mode: "parallel")
      new(parcela: parcela, geom_wkt: geom_wkt, target_areas: target_areas, mode: mode).call
    end

    def initialize(target_areas:, parcela: nil, geom_wkt: nil, mode: "parallel")
      @parcela = parcela
      @input_wkt = geom_wkt || parcela&.geom&.as_text
      @targets   = Array(target_areas).map(&:to_f).reject(&:zero?)
      @mode      = mode.to_s
    end

    def call
      return error("Selectează cel puțin 2 suprafețe țintă.") if @targets.size < 2
      return error("Mod necunoscut: #{@mode}. Doar 'parallel' implementat.") unless @mode == "parallel"
      return error("Lipsește geometria de divizat.") if @input_wkt.blank?

      orig_wkt   = @input_wkt
      total_area = sql_value("SELECT ST_Area(ST_GeomFromText($1, $2))", [orig_wkt, SRID]).to_f
      target_sum = @targets.sum

      axis = compute_axis(orig_wkt)
      return error("Nu pot calcula axa OMBR.") unless axis

      pieces = bisection_split(orig_wkt, axis, total_area)

      # Sortăm bucățile după proiecția centroidului pe axă (de la A la B)
      pieces = sort_pieces_along_axis(pieces, axis)

      return error("Diviziunea a produs #{pieces.size} bucăți (așteptam #{@targets.size}).") if pieces.size != @targets.size

      pieces_with_meta = pieces.each_with_index.map do |wkt, i|
        area = sql_value("SELECT ST_Area(ST_GeomFromText($1, $2))", [wkt, SRID]).to_f
        target = @targets[i]
        {
          wkt:         wkt,
          area_calc:   area.round(2),
          area_target: target.round(2),
          area_diff:   (area - target).round(2),
          ordinal:     i + 1
        }
      end

      Result.new(
        pieces: pieces_with_meta,
        diagnostics: {
          mode:        @mode,
          axis_length: axis[:length].round(3),
          total_area:  total_area.round(2),
          target_sum:  target_sum.round(2),
          area_ratio:  (total_area > 0 ? (target_sum / total_area).round(4) : nil)
        },
        error: nil
      )
    rescue => e
      Rails.logger.error "[ParcelDivider] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      error("Eroare internă: #{e.message}")
    end

    private

    # ── Axa principală ─────────────────────────────────────────────────────

    # Returnează hash { a: [x,y], b: [x,y], length:, dir: [dx,dy], normal: [nx,ny] }
    # unde a→b e latura lungă a dreptunghiului minim orientat.
    def compute_axis(wkt)
      env_wkt = sql_value("SELECT ST_AsText(ST_OrientedEnvelope(ST_GeomFromText($1, $2)))", [wkt, SRID])
      return nil unless env_wkt&.start_with?("POLYGON")

      coords = env_wkt.match(/POLYGON\s*\(\(\s*(.+?)\s*\)\)/m)[1]
                      .split(",").map { |p| p.strip.split(/\s+/).map(&:to_f) }
      # Polygon închis are 5 puncte (4 colțuri + closing). Folosim primele 4.
      corners = coords.first(4)
      sides = (0..3).map { |i| [corners[i], corners[(i + 1) % 4]] }

      side_lengths = sides.map { |a, b| Math.hypot(b[0] - a[0], b[1] - a[1]) }
      long_idx     = side_lengths.each_with_index.max[1]
      a, b         = sides[long_idx]
      length       = side_lengths[long_idx]
      dx, dy       = (b[0] - a[0]) / length, (b[1] - a[1]) / length
      { a: a, b: b, length: length, dir: [dx, dy], normal: [-dy, dx] }
    end

    # ── Tăiere cu căutare binară (Mod 1) ────────────────────────────────────
    #
    # Pentru fiecare cut, căutăm prin bisecție poziția pe axă unde tăierea
    # produce suprafața cumulativă țintă. Necesar pentru poligoane neregulate
    # (poziționarea proporțională ar funcționa doar pe dreptunghiuri).

    def bisection_split(orig_wkt, axis, _total_area)
      pieces    = []
      remaining = orig_wkt
      cur_t_min = 0.0
      cur_t_max = axis[:length]

      @targets[0..-2].each do |t|
        # Țintă pe piesa CURENTĂ (nu cumulativ): vrem ST_Area(first_piece_din_cut) ≈ t
        cut_t, parts = bisect_for_area(remaining, axis, t.to_f, cur_t_min, cur_t_max)
        if parts.nil? || parts.size < 2
          # tăierea a căzut în afara poligonului; lăsăm restul pe seama ultimei piese
          break
        end

        sorted = parts.sort_by { |p| project_centroid(p, axis) }
        pieces   << sorted.first
        remaining = sorted.size == 2 ? sorted.last : merge_pieces(sorted[1..])
        cur_t_min = cut_t
      end
      pieces << remaining
      pieces
    end

    # Întoarce [t_optim, [parts]] sau [nil, nil] dacă nu se poate tăia.
    def bisect_for_area(polygon_wkt, axis, target_area, t_min, t_max, max_iter: 30, tol_rel: 1e-3)
      lo = t_min
      hi = t_max
      best_t     = nil
      best_parts = nil

      max_iter.times do
        mid = (lo + hi) / 2.0
        line_wkt = cut_line_at(axis, mid)
        parts = split_into_parts(polygon_wkt, line_wkt)
        if parts.size < 2
          # Linia n-a tăiat; depinde de unde e poligonul rămas
          # Verificăm dacă centroidul piesei e înainte sau după mid; mutăm capătul corespunzător
          c_t = project_centroid(polygon_wkt, axis)
          if c_t < mid
            hi = mid
          else
            lo = mid
          end
          next
        end

        sorted   = parts.sort_by { |p| project_centroid(p, axis) }
        first_a  = sql_value("SELECT ST_Area(ST_GeomFromText($1, $2))", [ sorted.first, SRID ]).to_f
        best_t     = mid
        best_parts = sorted

        break if (first_a - target_area).abs / target_area.abs < tol_rel

        if first_a < target_area
          lo = mid
        else
          hi = mid
        end
      end

      [ best_t, best_parts ]
    end

    def cut_line_at(axis, t)
      pad = axis[:length] * 3
      cx  = axis[:a][0] + axis[:dir][0] * t
      cy  = axis[:a][1] + axis[:dir][1] * t
      nx, ny = axis[:normal]
      x1, y1 = cx - nx * pad, cy - ny * pad
      x2, y2 = cx + nx * pad, cy + ny * pad
      "LINESTRING(#{x1} #{y1}, #{x2} #{y2})"
    end

    def split_into_parts(polygon_wkt, line_wkt)
      sql = <<~SQL
        SELECT ST_AsText((ST_Dump(ST_Split(
          ST_GeomFromText($1, $3),
          ST_GeomFromText($2, $3)
        ))).geom) AS wkt
      SQL
      rows = ActiveRecord::Base.connection.exec_query(sql, "ParcelDivider", [ polygon_wkt, line_wkt, SRID ])
      rows.rows.flatten.compact
    end

    # Când o tăiere produce >2 piese (poligon ne-convex), reunim restul cu ST_Union
    # ca să rămână o singură geometrie de continuat.
    def merge_pieces(wkts)
      return wkts.first if wkts.size == 1
      placeholders = wkts.each_with_index.map { |_, i| "ST_GeomFromText($#{i + 1}, $#{wkts.size + 1})" }.join(", ")
      sql = "SELECT ST_AsText(ST_Union(ARRAY[#{placeholders}]))"
      sql_value(sql, wkts + [ SRID ])
    end

    def project_centroid(polygon_wkt, axis)
      cx, cy = sql_row(
        "SELECT ST_X(ST_Centroid(ST_GeomFromText($1, $2))), ST_Y(ST_Centroid(ST_GeomFromText($1, $2)))",
        [ polygon_wkt, SRID ]
      ).map(&:to_f)
      (cx - axis[:a][0]) * axis[:dir][0] + (cy - axis[:a][1]) * axis[:dir][1]
    end

    def sort_pieces_along_axis(pieces, axis)
      pieces.sort_by { |wkt| project_centroid(wkt, axis) }
    end

    # ── Helpers ──────────────────────────────────────────────────────────────

    def sql_value(sql, binds)
      ActiveRecord::Base.connection.exec_query(sql, "ParcelDivider", binds).rows.first&.first
    end

    def sql_row(sql, binds)
      ActiveRecord::Base.connection.exec_query(sql, "ParcelDivider", binds).rows.first
    end

    def error(msg)
      Result.new(pieces: [], diagnostics: {}, error: msg)
    end
  end
end
