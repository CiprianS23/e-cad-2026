class Parcel < ApplicationRecord
  belongs_to :land, optional: true

  validates :usecategory, length: { maximum: 50 }, allow_blank: true
  validates :measuredarea, numericality: true, allow_nil: true
end
