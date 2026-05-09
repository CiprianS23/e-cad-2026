class Registration < ApplicationRecord
  belongs_to :deed

  has_many :persons,                  dependent: :nullify
  has_many :registration_x_entities, dependent: :destroy
  has_many :lands,     through: :registration_x_entities
  has_many :buildings, through: :registration_x_entities
  has_many :individual_units, through: :registration_x_entities

  validates :registrationtype, presence: true
end
