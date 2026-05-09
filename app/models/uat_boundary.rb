class UatBoundary < ApplicationRecord
  validates :nat_code, presence: true

  scope :by_nat_code, ->(code) { where(nat_code: code) }
  scope :by_name, ->(name) { where("name ILIKE ?", "%#{name}%") }
end
