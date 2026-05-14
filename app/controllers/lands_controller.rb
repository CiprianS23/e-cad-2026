# Lands = teren cadastral (sursa unică pentru parcele, fie ele drafturi
# pre-juridice sau imobile cgxml complete). Înlocuiește vechiul ParceleCadastrale.
class LandsController < ApplicationController
  before_action :set_land, only: %i[show edit update destroy popup_info]

  def index
    @lands = filtrare.includes(:gis_geometry).page(params[:page]).per(50)
  end

  def geojson
    render json: geojson_collection(filtrare), content_type: "application/geo+json"
  end

  def lookup
    q = params[:q].to_s.strip
    return render json: [] if q.length < 2

    results = Land.where("cadgenno ILIKE ? OR e2identifier ILIKE ?", "%#{q}%", "%#{q}%")
                  .order(:cadgenno)
                  .limit(10)
                  .pluck(:id, :cadgenno, :e2identifier)
                  .map { |id, cad, e2| { id: id, numar_cadastral: cad.presence || e2.presence, judet: nil, localitate: nil } }
    render json: results
  end

  def show
    @gis = @land.gis_geometry
  end

  # JSON pentru popup pe hartă + populare formular sidebar la click pe parcelă:
  # Nr IE, proprietari, acte aferente dreptului de proprietate, adresă și
  # categorie folosință (din `parcels.usecategory`, prima ocurență).
  def popup_info
    sql = <<~SQL
      WITH ownership AS (
        SELECT DISTINCT r.id AS reg_id, r.deed_id, p.firstname, p.lastname, p.fatherinitial
        FROM registration_x_entities rxe
        JOIN registrations r ON r.id = rxe.registration_id
        LEFT JOIN persons p   ON p.registration_id = r.id
        WHERE rxe.land_id = #{@land.id.to_i}
          AND r.righttype ILIKE '%proprietat%'
      )
      SELECT
        (SELECT json_agg(DISTINCT jsonb_build_object(
          'firstname', firstname, 'lastname', lastname, 'fatherinitial', fatherinitial))
          FROM ownership WHERE lastname IS NOT NULL) AS owners,
        (SELECT json_agg(DISTINCT jsonb_build_object(
          'deedtype', d.deedtype, 'deednumber', d.deednumber,
          'authority', d.authority, 'deeddate', d.deeddate))
          FROM ownership o JOIN deeds d ON d.id = o.deed_id) AS deeds,
        (SELECT usecategory FROM parcels WHERE land_id = #{@land.id.to_i} LIMIT 1) AS usecategory
    SQL
    row  = ActiveRecord::Base.connection.select_one(sql)
    addr_row = ActiveRecord::Base.connection.select_one(<<~SQL)
      SELECT a.streetname, a.streettype, a.postalnumber, a.intravilan,
             COALESCE(su_loc.denumire_judet, su_uat.denumire_judet) AS judet,
             COALESCE(su_loc.denumire_uat,   su_uat.denumire_uat)   AS localitate
      FROM   lands l
      LEFT   JOIN addresses a      ON a.id = l.address_id
      LEFT   JOIN siruta_uats su_loc ON su_loc.cod_siruta = NULLIF(a.siruta, '')::int
      LEFT   JOIN siruta_uats su_uat ON su_uat.cod_siruta = NULLIF(a.sirsup, '')::int
      WHERE  l.id = #{@land.id.to_i}
    SQL
    render json: {
      cadgenno:     @land.cadgenno,
      e2identifier: @land.e2identifier,
      categoria_folosinta: row["usecategory"],
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

  def new
    @land = Land.new(measuredarea: 0, isnew: true)
    @land.build_gis_geometry(status: "draft")
  end

  def create
    attrs = land_params
    geom_wkt = attrs.delete(:geom_wkt)

    @land = Land.new(
      cadgenno:     attrs[:numar_cadastral],
      measuredarea: attrs[:suprafata_mp].presence&.to_f || 0,
      isnew:        true,
      notes:        build_notes(attrs)
    )

    if @land.save
      g = @land.build_gis_geometry(status: "draft", geom_wkt: geom_wkt)
      if g.save
        # Sub-record `parcels` cu usecategory pentru consistență cu modelul cgxml.
        if attrs[:categoria_folosinta].present?
          Parcel.create!(land_id: @land.id, usecategory: attrs[:categoria_folosinta], number: 1)
        end
        respond_to do |fmt|
          fmt.html { redirect_to @land, notice: "Parcela #{@land.label} a fost creată." }
          fmt.json { render json: { ok: true, redirect: land_path(@land) } }
        end
      else
        @land.destroy
        @land.errors.add(:base, g.errors.full_messages.first) if g.errors.any?
        render :new, status: :unprocessable_entity
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    attrs = land_params
    geom_wkt = attrs.delete(:geom_wkt)

    @land.cadgenno     = attrs[:numar_cadastral] if attrs.key?(:numar_cadastral)
    @land.measuredarea = attrs[:suprafata_mp].to_f if attrs[:suprafata_mp].present?
    @land.notes        = build_notes(attrs)

    if @land.save
      if geom_wkt.present?
        g = @land.gis_geometry || @land.build_gis_geometry(status: "draft")
        g.geom_wkt = geom_wkt
        unless g.save
          return respond_to do |fmt|
            fmt.html { redirect_to harta_path(edit_kind: "parcela", edit_id: @land.id), alert: g.errors.full_messages.to_sentence }
            fmt.json { render json: { ok: false, errors: g.errors.full_messages }, status: :unprocessable_entity }
          end
        end
      end
      respond_to do |fmt|
        fmt.html { redirect_to @land, notice: "Parcela a fost actualizată." }
        fmt.json { render json: { ok: true, redirect: land_path(@land) } }
      end
    else
      respond_to do |fmt|
        fmt.html { render :edit, status: :unprocessable_entity }
        fmt.json { render json: { ok: false, errors: @land.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  def destroy
    label = @land.label
    @land.destroy
    respond_to do |fmt|
      fmt.html { redirect_to lands_path, notice: "Parcela #{label} a fost ștearsă.", status: :see_other }
      fmt.json { render json: { ok: true } }
    end
  end

  private

  def filtrare
    scope = Land.with_geometry.order(created_at: :desc)
    scope = scope.where(gis_land_geometries: { status: params[:status] }) if params[:status].present?
    if params[:categoria_folosinta].present?
      scope = scope.joins("LEFT JOIN parcels p ON p.land_id = lands.id")
                   .where("p.usecategory = ?", params[:categoria_folosinta])
    end
    if params[:q].present?
      scope = scope.where("lands.cadgenno ILIKE ? OR lands.e2identifier ILIKE ?", "%#{params[:q]}%", "%#{params[:q]}%")
    end
    scope
  end

  def geojson_collection(scope)
    scope_sql = scope.select("lands.id, lands.cadgenno, lands.measuredarea")
                     .joins(:gis_geometry).to_sql

    sql = <<~SQL
      WITH q AS (#{scope_sql}),
      enriched AS (
        SELECT q.id,
               COALESCE(q.cadgenno, 'L#' || q.id) AS numar_cadastral,
               (SELECT usecategory FROM parcels WHERE land_id = q.id LIMIT 1) AS categoria_folosinta,
               g.suprafata_mp,
               g.status,
               ST_AsGeoJSON(g.geom, 6) AS geojson_wgs84
        FROM q
        JOIN gis_land_geometries g ON g.land_id = q.id
      )
      SELECT json_build_object(
        'type', 'FeatureCollection',
        'features', COALESCE(json_agg(
          json_build_object(
            'type', 'Feature',
            'geometry', e.geojson_wgs84::json,
            'properties', json_build_object(
              'id',                  e.id,
              'numar_cadastral',     e.numar_cadastral,
              'categoria_folosinta', e.categoria_folosinta,
              'suprafata_mp',        e.suprafata_mp,
              'status',              e.status
            )
          )
        ), '[]'::json)
      )
      FROM enriched e
    SQL

    ActiveRecord::Base.connection.select_value(sql)
  end

  def set_land
    @land = Land.find(params[:id])
  end

  # Acceptă param-namespace-uri flexibile pentru a păstra compatibilitate cu
  # formurile vechi (`parcela_cadastrala[...]`) cât și cu API-ul nou (`land[...]`).
  def land_params
    raw = params[:land] || params[:parcela_cadastrala] || ActionController::Parameters.new
    raw.permit(:numar_cadastral, :numar_topografic, :categoria_folosinta,
               :suprafata_mp, :judet, :localitate, :adresa,
               :proprietar, :cnp_cui_proprietar, :status, :geom_wkt)
  end

  def build_notes(attrs)
    parts = []
    parts << "Judet: #{attrs[:judet]}" if attrs[:judet].present?
    parts << "Localitate: #{attrs[:localitate]}" if attrs[:localitate].present?
    parts << "Adresa: #{attrs[:adresa]}" if attrs[:adresa].present?
    parts << "Proprietar: #{attrs[:proprietar]}" if attrs[:proprietar].present?
    parts << "CNP/CUI: #{attrs[:cnp_cui_proprietar]}" if attrs[:cnp_cui_proprietar].present?
    parts.any? ? parts.join(" | ") : nil
  end
end
