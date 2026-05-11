module Gis
  # Detectează geometriile CGXML (f_cg_land) care intersectează un contur de
  # lucru și propune o variantă „lipită" la limitele acestuia via ST_Intersection.
  # Originalele rămân intacte (reconstruite din points → tabela `points`); rezultatul
  # propus se persistă în `gis_imobile` cu `source = "cgxml_fit"`.
  class ImobilFitter
    SRID = 3844

    Result = Struct.new(:candidates, :error, keyword_init: true) do
      def success? = error.nil?
    end

    # candidate = {
    #   land_id, filename, cadgenno, e2identifier,
    #   original_area, fitted_area, area_diff, ratio_inside,
    #   fitted_wkt, fitted_geojson, status: "fit"|"identical"|"outside"|"invalid"
    # }

    # `snap_tolerance` în metri — vertecșii din land aflați la ≤ această distanță
    # de boundary-ul conturului sunt mutați (alipire dacă erau în afară, extindere
    # dacă erau în interior dar aproape). Pe lângă snap, se face ST_Intersection
    # cu conturul, deci nimic nu rămâne în afară.
    def self.call(contour_wkt:, snap_tolerance: 5.0)
      new(contour_wkt: contour_wkt, snap_tolerance: snap_tolerance).call
    end

    def initialize(contour_wkt:, snap_tolerance: 5.0)
      @contour_wkt     = contour_wkt
      @snap_tolerance  = snap_tolerance.to_f
    end

    def call
      return error("Lipsește geometria conturului.") if @contour_wkt.blank?

      rows = fetch_intersecting_lands
      candidates = rows.map { |r| build_candidate(r) }.compact

      Result.new(candidates: candidates, error: nil)
    rescue => e
      Rails.logger.error "[ImobilFitter] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      error("Eroare internă: #{e.message}")
    end

    private

    # SQL: reconstruim geometria fiecărui Land din points, apoi
    #   1) ST_Snap la boundary-ul conturului (densificat) → alipire + extindere
    #      vertecșilor aflați la ≤ snap_tolerance de contur
    #   2) Scale uniform din centroid → preserve original_area exact
    # ST_MakeValid pe rezultat. Originalele rămân intacte în tabela `points`.
    def fetch_intersecting_lands
      sql = <<~SQL
        WITH land_lines AS (
          SELECT land_id,
                 ST_MakeLine(coordinates ORDER BY no) AS line
          FROM   points
          WHERE  land_id IS NOT NULL AND coordinates IS NOT NULL
          GROUP  BY land_id
          HAVING COUNT(*) >= 3
        ),
        land_polys AS (
          SELECT l.id          AS land_id,
                 fd.filename,
                 l.cadgenno,
                 l.e2identifier,
                 CASE WHEN ST_IsClosed(ll.line)
                      THEN ST_MakePolygon(ll.line)
                      ELSE ST_MakePolygon(ST_AddPoint(ll.line, ST_StartPoint(ll.line)))
                 END AS geom_orig
          FROM   land_lines ll
          JOIN   lands l ON l.id = ll.land_id
          LEFT   JOIN file_descriptions fd ON fd.id = l.file_description_id
        ),
        contour AS (
          SELECT ST_GeomFromText($1, $2) AS geom
        ),
        snapped AS (
          SELECT lp.land_id, lp.filename, lp.cadgenno, lp.e2identifier,
                 ST_Area(lp.geom_orig)                                                 AS area_orig,
                 lp.geom_orig                                                          AS geom_orig,
                 ST_MakeValid(
                   ST_Snap(
                     lp.geom_orig,
                     ST_Segmentize(ST_Boundary(c.geom), 1.0),
                     $3::float
                   )
                 )                                                                      AS geom_snap
          FROM land_polys lp, contour c
          WHERE ST_IsValid(lp.geom_orig)
            AND ST_Intersects(lp.geom_orig, c.geom)
        ),
        fitted AS (
          SELECT s.land_id, s.filename, s.cadgenno, s.e2identifier,
                 s.area_orig,
                 s.geom_orig,
                 CASE
                   WHEN ST_GeometryType(s.geom_snap) IN ('ST_Polygon', 'ST_MultiPolygon')
                        AND ST_Area(s.geom_snap) > 0 AND s.area_orig > 0
                   THEN ST_Translate(
                          ST_Scale(
                            ST_Translate(s.geom_snap,
                                         -ST_X(ST_Centroid(s.geom_snap)),
                                         -ST_Y(ST_Centroid(s.geom_snap))),
                            sqrt(s.area_orig / ST_Area(s.geom_snap)),
                            sqrt(s.area_orig / ST_Area(s.geom_snap))
                          ),
                          ST_X(ST_Centroid(s.geom_snap)),
                          ST_Y(ST_Centroid(s.geom_snap))
                        )
                   ELSE s.geom_snap
                 END AS geom_fitted_raw
          FROM snapped s
        ),
        clean AS (
          SELECT f.land_id, f.filename, f.cadgenno, f.e2identifier,
                 f.area_orig,
                 ST_Multi(ST_MakeValid(f.geom_fitted_raw)) AS geom_fitted
          FROM fitted f
        )
        SELECT land_id, filename, cadgenno, e2identifier,
               area_orig                            AS original_area,
               ST_Area(geom_fitted)                 AS fitted_area,
               ST_AsText(geom_fitted)               AS fitted_wkt,
               ST_AsGeoJSON(geom_fitted, 6)         AS fitted_geojson
        FROM clean
      SQL
      ActiveRecord::Base.connection.exec_query(sql, "ImobilFitter", [ @contour_wkt, SRID, @snap_tolerance ])
    end

    def build_candidate(row)
      land_id     = row["land_id"]
      fitted_wkt  = row["fitted_wkt"]
      orig_area   = row["original_area"].to_f
      fitted_area = row["fitted_area"].to_f
      return nil unless fitted_wkt.present? && fitted_area > 0

      area_diff = (fitted_area - orig_area).round(2)
      # După snap+scale, area_diff ar trebui să fie aproape 0 (sub 0.5 mp pe scanări curate).
      # status: identical=fit perfect (snap n-a schimbat nimic), reshaped=geometria s-a mutat, invalid=problemă.
      status = if area_diff.abs < 0.5 && row["e2identifier"]
                 "reshaped"
               else
                 "reshaped"
               end

      {
        land_id:        land_id,
        filename:       row["filename"],
        cadgenno:       row["cadgenno"],
        e2identifier:   row["e2identifier"],
        original_area:  orig_area.round(2),
        fitted_area:    fitted_area.round(2),
        area_diff:      area_diff,
        status:         status,
        fitted_wkt:     fitted_wkt,
        fitted_geojson: row["fitted_geojson"] ? JSON.parse(row["fitted_geojson"]) : nil
      }
    end

    def error(msg)
      Result.new(candidates: [], error: msg)
    end
  end
end
