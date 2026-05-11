class FixGisGcpOrdinals < ActiveRecord::Migration[8.0]
  # Bug: coloana avea default: 0, iar before_validation `self.ordinal ||= ...`
  # nu suprascria (0 nu e falsy în Ruby). Toate GCP-urile primeau ordinal 0
  # → în UI apăreau toate cu "1" (cp.ordinal + 1).
  #
  # Fix: scoatem default-ul (column nullable in setter, but always set by
  # before_validation). Backfill ordinals pe rândurile existente.
  def up
    change_column_default :gis_georef_control_points, :ordinal, nil

    # Backfill: pentru fiecare plan, ordinal = 0, 1, 2, ... în ordinea de
    # inserție (id asc) — convenția cea mai logică pentru date deja create.
    GisGeorefPlan.includes(:control_points).find_each do |plan|
      plan.control_points.order(:id).each_with_index do |cp, i|
        cp.update_columns(ordinal: i) if cp.ordinal != i
      end
    end
  end

  def down
    change_column_default :gis_georef_control_points, :ordinal, 0
  end
end
