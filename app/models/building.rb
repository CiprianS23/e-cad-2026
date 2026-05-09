class Building < ApplicationRecord
  belongs_to :land
  belongs_to :address, optional: true

  has_many :building_common_parts,  dependent: :destroy
  has_many :individual_units,       dependent: :destroy
  has_many :points,                 dependent: :destroy
  has_many :registration_x_entities, dependent: :destroy
  has_many :registrations,          through: :registration_x_entities
  has_many :contested_x_entities,   dependent: :destroy
  has_many :contesteds,             through: :contested_x_entities

  validates :buildno, presence: true
  validates :islegal, inclusion: { in: [ true, false ] }
end
