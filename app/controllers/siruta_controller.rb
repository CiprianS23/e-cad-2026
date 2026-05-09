class SirutaController < ApplicationController
  def autocomplete
    q     = params[:q].to_s.strip
    type  = params[:type].to_s
    judet = params[:judet].to_s.strip

    results = case type
              when "judet"    then judete(q)
              when "localitate" then localitati(q, judet)
              else []
              end

    render json: results
  end

  private

  def judete(q)
    scope = SirutaUat.select(:denumire_judet).distinct
    scope = scope.where("unaccent(lower(denumire_judet)) LIKE unaccent(lower(?))", "%#{q}%") if q.present?
    scope.order(:denumire_judet).limit(15).map do |r|
      display = normalize(r.denumire_judet)
      { value: display, label: display }
    end
  end

  def localitati(q, judet)
    scope = SirutaUat.where(tip_uat: [12, 13, 14, 15, 16])
    scope = scope.where("unaccent(lower(denumire_judet)) LIKE unaccent(lower(?))", "%#{judet}%") if judet.present?
    scope = scope.where("unaccent(lower(denumire_uat)) LIKE unaccent(lower(?))", "%#{q}%")      if q.present?
    scope.order(:denumire_uat).limit(15).map do |r|
      display = normalize(r.denumire_uat)
      { value: display, label: "#{display} (#{r.tip_uat_abrev})", cod_siruta: r.cod_siruta }
    end
  end

  def normalize(str)
    str.gsub(/\b\w+/) { |m| m.capitalize }
  end
end
