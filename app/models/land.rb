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

  validates :measuredarea, numericality: { greater_than_or_equal_to: 0 }
end
