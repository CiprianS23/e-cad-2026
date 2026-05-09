class Address < ApplicationRecord
  has_many :lands,     dependent: :nullify
  has_many :buildings, dependent: :nullify
  has_many :persons,   dependent: :nullify

  validates :siruta, length: { maximum: 50 }, allow_blank: true
end
