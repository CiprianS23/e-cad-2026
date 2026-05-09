class IndividualUnit < ApplicationRecord
  belongs_to :building, optional: true

  has_many :registration_x_entities, dependent: :destroy
  has_many :registrations,           through: :registration_x_entities
  has_many :contested_x_entities,    dependent: :destroy
  has_many :contesteds,              through: :contested_x_entities

  validates :identifier, presence: true, length: { maximum: 50 }
end
