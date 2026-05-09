class BuildingCommonPart < ApplicationRecord
  belongs_to :building, optional: true

  validates :commonparttype, length: { maximum: 255 }, allow_blank: true
end
