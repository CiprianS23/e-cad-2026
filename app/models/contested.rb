class Contested < ApplicationRecord
  has_many :contested_x_entities, dependent: :destroy
  has_many :lands,           through: :contested_x_entities
  has_many :buildings,       through: :contested_x_entities
  has_many :individual_units, through: :contested_x_entities
end
