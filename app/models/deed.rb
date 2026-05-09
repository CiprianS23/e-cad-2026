class Deed < ApplicationRecord
  belongs_to :file_description
  has_many   :registrations, dependent: :destroy

  validates :deednumber, presence: true, length: { maximum: 200 }
  validates :deedtype,   presence: true, length: { maximum: 255 }
  validates :authority,  presence: true, length: { maximum: 50 }
end
