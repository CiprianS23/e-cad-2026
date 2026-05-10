class ParceleCadastraleController < ApplicationController
  before_action :set_parcela, only: %i[show edit update destroy]

  def index
    @parcele = filtrare
  end

  def geojson
    render json: geojson_collection(filtrare)
  end

  def lookup
    q = params[:q].to_s.strip
    return render json: [] if q.length < 2

    results = ParcelaCadastrala
                .where("numar_cadastral ILIKE ?", "%#{q}%")
                .order(:numar_cadastral)
                .limit(10)
                .pluck(:id, :numar_cadastral, :judet, :localitate)
                .map { |id, nr, jud, loc| { id: id, numar_cadastral: nr, judet: jud, localitate: loc } }
    render json: results
  end

  def show; end

  def new
    @parcela = ParcelaCadastrala.new(status: "activ")
  end

  def create
    @parcela = ParcelaCadastrala.new(parcela_params)
    if @parcela.save
      redirect_to @parcela, notice: "Parcela #{@parcela.numar_cadastral} a fost creată."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @parcela.update(parcela_params)
      redirect_to @parcela, notice: "Parcela a fost actualizată."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @parcela.destroy
    redirect_to parcele_cadastrale_path, notice: "Parcela a fost ștearsă.", status: :see_other
  end

  private

  def filtrare
    scope = ParcelaCadastrala.order(created_at: :desc)
    scope = scope.in_judet(params[:judet])                                    if params[:judet].present?
    scope = scope.where(categoria_folosinta: params[:categoria_folosinta])     if params[:categoria_folosinta].present?
    scope = scope.where(status: params[:status])                               if params[:status].present?
    scope = scope.where("numar_cadastral ILIKE ?", "%#{params[:q]}%")          if params[:q].present?
    scope
  end

  def geojson_collection(scope)
    subquery = scope.where.not(geom: nil)
                    .select(:id, :numar_cadastral, :categoria_folosinta,
                            :suprafata_mp, :judet, :localitate, :proprietar, :status,
                            "ST_AsGeoJSON(geom, 6) AS geojson_wgs84")
                    .to_sql

    sql = <<~SQL
      SELECT json_build_object(
        'type', 'FeatureCollection',
        'features', COALESCE(json_agg(
          json_build_object(
            'type', 'Feature',
            'geometry', q.geojson_wgs84::json,
            'properties', json_build_object(
              'id',                  q.id,
              'numar_cadastral',     q.numar_cadastral,
              'categoria_folosinta', q.categoria_folosinta,
              'suprafata_mp',        q.suprafata_mp,
              'judet',               q.judet,
              'localitate',          q.localitate,
              'proprietar',          q.proprietar,
              'status',              q.status
            )
          )
        ), '[]'::json)
      ) AS geojson
      FROM (#{subquery}) AS q
    SQL

    ActiveRecord::Base.connection.select_value(sql)
  end

  def set_parcela
    @parcela = ParcelaCadastrala.find(params[:id])
  end

  def parcela_params
    params.require(:parcela_cadastrala).permit(
      :numar_cadastral, :numar_topografic, :categoria_folosinta,
      :suprafata_mp, :judet, :localitate, :adresa,
      :proprietar, :cnp_cui_proprietar, :status, :geom_wkt
    )
  end
end
