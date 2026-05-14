class Land < ApplicationRecord
  belongs_to :file_description, optional: true
  belongs_to :address,          optional: true

  has_many :buildings,              dependent: :destroy
  has_many :parcels,                dependent: :destroy
  has_many :points,                 dependent: :destroy, foreign_key: :land_id
  has_many :registration_x_entities, dependent: :destroy
  has_many :registrations,          through: :registration_x_entities
  has_many :contested_x_entities,   dependent: :destroy
  has_many :contesteds,             through: :contested_x_entities

  # Cache geometric pentru digitizare interactivă (vezi GisLandGeometry).
  # Lipsește pe land-urile vechi importate din cgxml care n-au fost încă „fittate".
  has_one :gis_geometry, class_name: "GisLandGeometry", dependent: :destroy

  # Un land devine „imobil" în sensul juridic când are cel puțin o registration
  # (= intabulare în CF). Înainte de asta, e doar geometrie + metadata.
  def imobil? = registrations.exists?

  def draft? = !imobil?

  # Eticheta vizibilă pentru parcelă: cadgenno-ul (oficial cgxml sau "DR-..." pt
  # drafturi din digitizare), fallback la id.
  def label
    cadgenno.presence || "L##{id}"
  end

  # Toate lands cu geometrie în cache (digitizate sau cgxml-fittate). Returnează
  # un scope util pentru hartă / export / digitizare.
  scope :with_geometry, -> { joins(:gis_geometry) }
  scope :drafts,        -> { joins(:gis_geometry).where(gis_land_geometries: { status: "draft" }) }

  validates :measuredarea, numericality: { greater_than_or_equal_to: 0 }
end
