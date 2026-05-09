class SirutaUat < ApplicationRecord
  TIP_UAT = {
    11 => "Consiliu Județean",
    12 => "Municipiu",
    13 => "Oraș",
    14 => "Comună",
    15 => "Sector București",
    16 => "Primărie Sector București"
  }.freeze

  validates :cod_siruta,     presence: true, uniqueness: true
  validates :cod_judet,      presence: true
  validates :denumire_judet, presence: true
  validates :tip_uat,        presence: true
  validates :tip_uat_abrev,  presence: true
  validates :denumire_uat,   presence: true

  scope :judete, -> { where(tip_uat: 11).order(:cod_judet) }
  scope :municipii, -> { where(tip_uat: 12) }
  scope :orase, -> { where(tip_uat: 13) }
  scope :comune, -> { where(tip_uat: 14) }

  def tip_uat_name
    TIP_UAT[tip_uat] || tip_uat_abrev
  end

  def self.search(query)
    where("unaccent(lower(denumire_uat)) LIKE unaccent(lower(?))", "%#{query}%")
  end
end
