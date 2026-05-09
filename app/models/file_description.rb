class FileDescription < ApplicationRecord
  has_many :lands,    dependent: :nullify
  has_many :deeds,    dependent: :destroy
  has_many :persons,  dependent: :nullify

  validates :filename, presence: true, length: { maximum: 50 }
end
