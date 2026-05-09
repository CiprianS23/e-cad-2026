class Deed < ApplicationRecord
  belongs_to :file_description
  has_many   :registrations, dependent: :destroy

  validates :deednumber, presence: true
  validates :deedtype,   presence: true
  validates :authority,  presence: true
end
