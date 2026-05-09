class Person < ApplicationRecord
  self.table_name = "persons"

  belongs_to :address,          optional: true
  belongs_to :file_description, optional: true
  belongs_to :registration,     optional: true

  validates :firstname, presence: true, length: { maximum: 255 }
  validates :idcode, length: { maximum: 50 }, allow_blank: true
end
