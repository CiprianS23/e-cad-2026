class ContestedXEntity < ApplicationRecord
  belongs_to :contested,      optional: true
  belongs_to :land,           optional: true
  belongs_to :building,       optional: true
  belongs_to :individual_unit, optional: true
end
