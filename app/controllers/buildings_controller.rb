# Buildings = construcție cadastrală. Sursa unică pentru clădiri, fie ele
# drafturi pre-juridice sau imobile cgxml complete.
class BuildingsController < ApplicationController
  before_action :set_building, only: %i[show update destroy popup_info]

  def show
    @gis = @building.gis_geometry
  end

  # JSON pentru popup pe hartă + populare form sidebar la click pe clădire.
  def popup_info
    sql = <<~SQL
      WITH ownership AS (
        SELECT DISTINCT r.id AS reg_id, r.deed_id, p.firstname, p.lastname, p.fatherinitial
        FROM registration_x_entities rxe
        JOIN registrations r ON r.id = rxe.registration_id
        LEFT JOIN persons p   ON p.registration_id = r.id
        WHERE rxe.building_id = #{@building.id.to_i}
          AND r.righttype ILIKE '%proprietat%'
      )
      SELECT
        (SELECT json_agg(DISTINCT jsonb_build_object(
          'firstname', firstname, 'lastname', lastname, 'fatherinitial', fatherinitial))
          FROM ownership WHERE lastname IS NOT NULL) AS owners,
        (SELECT json_agg(DISTINCT jsonb_build_object(
          'deedtype', d.deedtype, 'deednumber', d.deednumber,
          'authority', d.authority, 'deeddate', d.deeddate))
          FROM ownership o JOIN deeds d ON d.id = o.deed_id) AS deeds
    SQL
    row = ActiveRecord::Base.connection.select_one(sql)
    addr_row = ActiveRecord::Base.connection.select_one(<<~SQL)
      SELECT a.streetname, a.streettype, a.postalnumber,
             COALESCE(su_loc.denumire_judet, su_uat.denumire_judet) AS judet,
             COALESCE(su_loc.denumire_uat,   su_uat.denumire_uat)   AS localitate
      FROM   buildings b
      LEFT   JOIN addresses a      ON a.id = b.address_id
      LEFT   JOIN siruta_uats su_loc ON su_loc.cod_siruta = NULLIF(a.siruta, '')::int
      LEFT   JOIN siruta_uats su_uat ON su_uat.cod_siruta = NULLIF(a.sirsup, '')::int
      WHERE  b.id = #{@building.id.to_i}
    SQL
    render json: {
      cadgenno:     @building.cadgenno,
      e2identifier: @building.e2identifier,
      destinatie:   @building.buildingdestination,
      levelsno:     @building.levelsno,
      address:      addr_row && {
        judet:      addr_row["judet"],
        localitate: addr_row["localitate"],
        strada:     [addr_row["streettype"], addr_row["streetname"]].compact.join(" ").presence,
        numar:      addr_row["postalnumber"]
      },
      owners:       row["owners"] ? JSON.parse(row["owners"]) : [],
      deeds:        row["deeds"]  ? JSON.parse(row["deeds"])  : []
    }
  end

  def update
    attrs = building_params
    geom_wkt = attrs.delete(:geom_wkt)

    @building.cadgenno            = attrs[:numar_cadastral] if attrs.key?(:numar_cadastral)
    @building.buildingdestination = attrs[:destinatie] if attrs.key?(:destinatie)
    @building.measuredarea        = attrs[:suprafata_construita_mp].to_f if attrs[:suprafata_construita_mp].present?
    @building.notes               = build_notes(attrs)

    if @building.save(validate: false)
      if geom_wkt.present?
        g = @building.gis_geometry || @building.build_gis_geometry(status: "draft")
        g.geom_wkt = geom_wkt
        unless g.save
          return respond_to do |fmt|
            fmt.html { redirect_to harta_path(edit_kind: "cladire", edit_id: @building.id), alert: g.errors.full_messages.to_sentence }
            fmt.json { render json: { ok: false, errors: g.errors.full_messages }, status: :unprocessable_entity }
          end
        end
      end
      respond_to do |fmt|
        fmt.html { redirect_to building_path(@building), notice: "Clădirea a fost actualizată." }
        fmt.json { render json: { ok: true, redirect: building_path(@building) } }
      end
    else
      respond_to do |fmt|
        fmt.html { redirect_to harta_path(edit_kind: "cladire", edit_id: @building.id),
                                alert: @building.errors.full_messages.to_sentence }
        fmt.json { render json: { ok: false, errors: @building.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  def destroy
    label = @building.label
    @building.destroy
    respond_to do |fmt|
      fmt.html { redirect_to harta_path, notice: "Clădirea #{label} a fost ștearsă.", status: :see_other }
      fmt.json { render json: { ok: true } }
    end
  end

  def create
    attrs = building_params
    geom_wkt = attrs.delete(:geom_wkt)
    parent_id = attrs.delete(:parcela_cadastrala_id).presence&.to_i

    # land_id e NOT NULL în lands schema — îl găsim spatial din geometry când
    # formul nu îl trimite explicit (cazul digitizării libere).
    parent_id ||= find_parent_land_id(geom_wkt) if geom_wkt.present?
    if parent_id.blank?
      return respond_to do |fmt|
        fmt.html { redirect_to harta_path, alert: "Nu există parcelă digitizată care să conțină clădirea." }
        fmt.json { render json: { ok: false, errors: ["Nu există parcelă părinte."] }, status: :unprocessable_entity }
      end
    end

    @building = Building.new(
      cadgenno:            attrs[:numar_cadastral],
      buildingdestination: attrs[:destinatie],
      measuredarea:        attrs[:suprafata_construita_mp].presence&.to_f || 0,
      buildno:             next_buildno_for_draft,
      islegal:             false,
      land_id:             parent_id,
      notes:               build_notes(attrs)
    )

    @building.save(validate: false)
    g = @building.build_gis_geometry(status: "draft", geom_wkt: geom_wkt)
    if g.save
      respond_to do |fmt|
        fmt.html { redirect_to building_path(@building), notice: "Clădirea #{@building.label} a fost creată." }
        fmt.json { render json: { ok: true, redirect: building_path(@building) } }
      end
    else
      @building.destroy
      respond_to do |fmt|
        fmt.html { redirect_to harta_path, alert: g.errors.full_messages.to_sentence }
        fmt.json { render json: { ok: false, errors: g.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  def geojson
    render json: geojson_collection, content_type: "application/geo+json"
  end

  private

  def geojson_collection
    sql = <<~SQL
      WITH enriched AS (
        SELECT b.id,
               COALESCE(b.cadgenno, 'B#' || b.id) AS numar_cadastral,
               b.buildingdestination AS destinatie,
               g.suprafata_mp AS suprafata_construita_mp,
               g.status,
               ST_AsGeoJSON(g.geom, 6) AS geojson_wgs84
        FROM gis_building_geometries g
        JOIN buildings b ON b.id = g.building_id
      )
      SELECT json_build_object(
        'type', 'FeatureCollection',
        'features', COALESCE(json_agg(
          json_build_object(
            'type', 'Feature',
            'geometry', e.geojson_wgs84::json,
            'properties', json_build_object(
              'id',                      e.id,
              'numar_cadastral',         e.numar_cadastral,
              'destinatie',              e.destinatie,
              'suprafata_construita_mp', e.suprafata_construita_mp,
              'status',                  e.status,
              'entity_type',             'cladire'
            )
          )
        ), '[]'::json)
      )
      FROM enriched e
    SQL
    ActiveRecord::Base.connection.select_value(sql)
  end

  def set_building
    @building = Building.find(params[:id])
  end

  def building_params
    raw = params[:building] || params[:cladire_cadastrala] || ActionController::Parameters.new
    raw.permit(:numar_cadastral, :destinatie, :regim_inaltime,
               :suprafata_construita_mp, :judet, :localitate,
               :proprietar, :status, :geom_wkt, :parcela_cadastrala_id)
  end

  def build_notes(attrs)
    parts = []
    parts << "Regim înălțime: #{attrs[:regim_inaltime]}" if attrs[:regim_inaltime].present?
    parts << "Judet: #{attrs[:judet]}" if attrs[:judet].present?
    parts << "Localitate: #{attrs[:localitate]}" if attrs[:localitate].present?
    parts << "Proprietar: #{attrs[:proprietar]}" if attrs[:proprietar].present?
    parts.any? ? parts.join(" | ") : nil
  end

  def next_buildno_for_draft
    (Building.maximum(:buildno) || 0) + 1
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
end
