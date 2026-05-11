module Gis
  # Endpoint-uri pentru Faza 2 din workflow-ul de divizare:
  #   - fit_preview: detectează imobile CGXML care intersectează un contur și
  #     propune geometrii „lipite" la limitele acestuia. NU persistă.
  #   - fit_apply: persistă în `gis_imobile` (source = "cgxml_fit") imobilele
  #     selectate de utilizator.
  class ImobileController < ApplicationController
    protect_from_forgery with: :null_session, if: -> { request.format.json? }
    before_action :ensure_owner_token

    def fit_preview
      contour = find_contour
      return render(json: { ok: false, error: "Conturul nu există." }, status: :not_found) unless contour

      result = Gis::ImobilFitter.call(contour_wkt: contour.geom.as_text)
      return render(json: { ok: false, error: result.error }, status: :unprocessable_entity) unless result.success?

      render json: {
        ok: true,
        contour_id: contour.id,
        candidates: result.candidates.map { |c| candidate_payload(c) }
      }
    end

    # GET-ul logic: returnează zonele rămase (contour minus toate gis_imobile)
    # ca FeatureCollection cu area per zonă. Folosit la Faza 3 pentru a-i arăta
    # utilizatorului unde mai e loc de parcelat.
    def remaining_zones
      contour = find_contour
      return render(json: { ok: false, error: "Conturul nu există." }, status: :not_found) unless contour

      sql = <<~SQL
        WITH contour AS (
          SELECT ST_GeomFromText($1, $2) AS geom
        ),
        imobile_union AS (
          SELECT ST_UnaryUnion(ST_Collect(geom_corrected)) AS geom
          FROM gis_imobile
          WHERE proiect_divizare_id = $3
            AND source IN ('cgxml_fit', 'divizare_zona', 'manual')
        ),
        diff AS (
          SELECT ST_Difference(c.geom, COALESCE(iu.geom, ST_GeomFromText('POLYGON EMPTY', $2))) AS geom
          FROM contour c LEFT JOIN imobile_union iu ON TRUE
        ),
        zones AS (
          SELECT (ST_Dump(geom)).geom AS poly
          FROM diff
          WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom)
        )
        SELECT row_number() OVER ()              AS idx,
               ST_Area(poly)                     AS area,
               ST_AsText(poly)                   AS wkt,
               ST_AsGeoJSON(poly, 6)             AS geojson
        FROM zones
        WHERE ST_Area(poly) > 0.5
        ORDER BY area DESC
      SQL
      rows = ActiveRecord::Base.connection.exec_query(sql, "RemainingZones", [ contour.geom.as_text, GisImobil::FACTORY.srid, contour.id ])
      features = rows.map do |r|
        {
          idx:      r["idx"],
          area:     r["area"].to_f.round(2),
          wkt:      r["wkt"],
          geometry: JSON.parse(r["geojson"])
        }
      end
      render json: {
        ok:           true,
        contour_id:   contour.id,
        contour_area: contour.area&.to_f,
        zones:        features
      }
    end

    # Simulează feasibilitatea unei alocări: are zona aleasă suficientă suprafață
    # pentru lista de parcele (suprafețe țintă)? Pur aritmetic — nu cuts.
    def simulate_fit
      zone_area    = params[:zone_area].to_f
      target_areas = Array(params[:target_areas]).map(&:to_f).reject { |t| t <= 0 }
      return render(json: { ok: false, error: "Aria zonei invalidă." }, status: :unprocessable_entity) if zone_area <= 0
      return render(json: { ok: false, error: "Nicio suprafață țintă." }, status: :unprocessable_entity) if target_areas.empty?

      sum    = target_areas.sum
      diff   = zone_area - sum
      ratio  = sum / zone_area
      verdict =
        if diff.abs < 0.5                  then "perfect"
        elsif diff > 0                     then "fits_with_surplus"
        else                                    "overflow"
        end

      render json: {
        ok:           true,
        zone_area:    zone_area.round(2),
        target_sum:   sum.round(2),
        target_count: target_areas.size,
        diff:         diff.round(2),
        fill_ratio:   ratio.round(4),
        verdict:      verdict,
        surplus_mp:   diff > 0 ? diff.round(2) : 0,
        deficit_mp:   diff < 0 ? (-diff).round(2) : 0,
        avg_target:   (sum / target_areas.size).round(2),
        min_target:   target_areas.min.round(2),
        max_target:   target_areas.max.round(2)
      }
    end

    def fit_apply
      contour = find_contour
      return render(json: { ok: false, error: "Conturul nu există." }, status: :not_found) unless contour

      land_ids = Array(params[:land_ids]).map(&:to_i).uniq.reject(&:zero?)
      return render(json: { ok: false, error: "Selectează cel puțin un imobil." }, status: :unprocessable_entity) if land_ids.empty?

      result = Gis::ImobilFitter.call(contour_wkt: contour.geom.as_text)
      return render(json: { ok: false, error: result.error }, status: :unprocessable_entity) unless result.success?

      eligible = result.candidates.select { |c| land_ids.include?(c[:land_id].to_i) && %w[fit identical].include?(c[:status]) }
      created = []
      skipped = []

      ActiveRecord::Base.transaction do
        eligible.each do |c|
          # Înlocuim orice fit_cgxml anterior pentru același land — un singur
          # imobil corectat per land per proiect; istoricul rămâne în `points`.
          GisImobil.where(land_id: c[:land_id], source: "cgxml_fit").destroy_all

          imb = GisImobil.new(
            land_id:             c[:land_id],
            source:              "cgxml_fit",
            proiect_divizare_id: contour.id,  # placeholder; legăm de „proiect" via contur deocamdată
            corrected_by:        @owner_token
          )
          imb.geom_corrected = GisImobil::FACTORY.parse_wkt(c[:fitted_wkt])
          if imb.save
            created << { land_id: c[:land_id], gis_imobil_id: imb.id, area: c[:fitted_area] }
          else
            skipped << { land_id: c[:land_id], errors: imb.errors.full_messages }
            raise ActiveRecord::Rollback
          end
        end
      end

      if skipped.any?
        render json: { ok: false, error: "Nu pot crea unele imobile", skipped: skipped }, status: :unprocessable_entity
      else
        render json: { ok: true, created: created }
      end
    end

    private

    def find_contour
      GisContour.for_owner(@owner_token).find_by(id: params[:contour_id])
    end

    def candidate_payload(c)
      {
        land_id:        c[:land_id],
        filename:       c[:filename],
        cadgenno:       c[:cadgenno],
        e2identifier:   c[:e2identifier],
        original_area:  c[:original_area],
        fitted_area:    c[:fitted_area],
        area_diff:      c[:area_diff],
        ratio_inside:   c[:ratio_inside],
        status:         c[:status],
        geometry:       c[:fitted_geojson]
      }
    end

    def ensure_owner_token
      if Rails.env.development?
        @owner_token = "dev-shared"
        return
      end
      cookies.signed[:gis_owner_token] ||= {
        value:    SecureRandom.uuid,
        expires:  1.year.from_now,
        httponly: true
      }
      @owner_token = cookies.signed[:gis_owner_token]
    end
  end
end
