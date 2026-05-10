class CladiriCadastraleController < ApplicationController
  before_action :set_cladire, only: :show

  def show; end

  def create
    @cladire = CladireCadastrala.new(cladire_params)
    if @cladire.save
      redirect_to cladiri_cadastrale_path(@cladire),
                  notice: "Clădirea #{@cladire.numar_cadastral} a fost creată."
    else
      redirect_to harta_path,
                  alert: @cladire.errors.full_messages.to_sentence
    end
  end

  def geojson
    render json: geojson_collection, content_type: "application/geo+json"
  end

  private

  def geojson_collection
    subquery = CladireCadastrala.where.not(geom: nil)
                                .select(:id, :numar_cadastral, :destinatie, :regim_inaltime,
                                        :suprafata_construita_mp, :judet, :localitate,
                                        :proprietar, :status,
                                        "ST_AsGeoJSON(ST_Transform(geom, 4326), 6) AS geojson_wgs84")
                                .to_sql

    sql = <<~SQL
      SELECT json_build_object(
        'type', 'FeatureCollection',
        'features', COALESCE(json_agg(
          json_build_object(
            'type', 'Feature',
            'geometry', q.geojson_wgs84::json,
            'properties', json_build_object(
              'id',                      q.id,
              'numar_cadastral',         q.numar_cadastral,
              'destinatie',              q.destinatie,
              'regim_inaltime',          q.regim_inaltime,
              'suprafata_construita_mp', q.suprafata_construita_mp,
              'judet',                   q.judet,
              'localitate',              q.localitate,
              'proprietar',              q.proprietar,
              'status',                  q.status,
              'entity_type',             'cladire'
            )
          )
        ), '[]'::json)
      )
      FROM (#{subquery}) AS q
    SQL

    ActiveRecord::Base.connection.select_value(sql)
  end

  def set_cladire
    @cladire = CladireCadastrala.find(params[:id])
  end

  def cladire_params
    params.require(:cladire_cadastrala).permit(
      :numar_cadastral, :destinatie, :regim_inaltime,
      :suprafata_construita_mp, :judet, :localitate,
      :proprietar, :status, :geom_wkt, :parcela_cadastrala_id
    )
  end
end
