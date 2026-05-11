class GisGeorefControlPoint < ApplicationRecord
  # Punct de control (GCP) pentru transformarea unui plan vechi:
  # (pixel_x, pixel_y) pe imaginea sursă ↔ (world_x, world_y) în EPSG:3844.
  belongs_to :gis_georef_plan, class_name: "GisGeorefPlan"

  validates :pixel_x, :pixel_y, :world_x, :world_y, presence: true, numericality: true
  validates :ordinal, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate  :world_not_duplicate_in_plan, on: :create

  before_validation :assign_default_ordinal, on: :create

  # Blochează GCP cu world identic cu unul existent în același plan (tol 1 cm).
  # gdalwarp eșuează cu "Transform is not solvable" pentru puncte duplicate sau
  # coliniare. JS-ul deja previne dar lăsăm și server-side ca defense-in-depth.
  WORLD_DUP_TOL = 0.01
  def world_not_duplicate_in_plan
    return unless gis_georef_plan_id && world_x && world_y
    dup = self.class
            .where(gis_georef_plan_id: gis_georef_plan_id)
            .where.not(id: id)
            .where("ABS(world_x - ?) < ? AND ABS(world_y - ?) < ?",
                   world_x, WORLD_DUP_TOL, world_y, WORLD_DUP_TOL)
            .first
    if dup
      errors.add(:base,
        "World (#{world_x.round(2)}, #{world_y.round(2)}) coincide cu GCP ##{dup.ordinal + 1}. " \
        "Alege un alt punct — transformarea ar fi degenerată.")
    end
  end

  # Asignarea ordinalului e SERVER-AUTHORITATIVE: clientul nu trimite ordinal,
  # serverul îl calculează mereu pe create. Folosim `=` (nu `||=`) pentru a fi
  # robusti la schema cache stale — dacă Rails crede încă `default: 0`,
  # `cp.ordinal` returnează 0 la new() iar `||=` nu ar suprascrie.
  def assign_default_ordinal
    self.ordinal = (gis_georef_plan&.control_points&.where.not(id: id)&.maximum(:ordinal) || -1) + 1
  end
end
