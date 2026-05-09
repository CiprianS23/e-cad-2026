class RegistrationXEntity < ApplicationRecord
  belongs_to :registration,   optional: true
  belongs_to :land,           optional: true
  belongs_to :building,       optional: true
  belongs_to :individual_unit, optional: true
end
