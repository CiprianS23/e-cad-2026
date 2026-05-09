class AddUniqueIndexToFileDescriptionsFilename < ActiveRecord::Migration[8.1]
  def up
    # Duplicate ids to remove — keep MIN(id) per filename (first import)
    dup_ids = select_values(<<~SQL).map(&:to_i)
      SELECT id FROM file_descriptions
      WHERE id NOT IN (SELECT MIN(id) FROM file_descriptions GROUP BY filename)
    SQL

    if dup_ids.any?
      ids = dup_ids.join(", ")

      # Collect descendant ids needed for cascade
      deed_ids = select_values("SELECT id FROM deeds WHERE file_description_id IN (#{ids})").map(&:to_i)
      land_ids = select_values("SELECT id FROM lands WHERE file_description_id IN (#{ids})").map(&:to_i)

      reg_ids   = deed_ids.any? ? select_values("SELECT id FROM registrations WHERE deed_id IN (#{deed_ids.join(',')})").map(&:to_i) : []
      bld_ids   = land_ids.any? ? select_values("SELECT id FROM buildings WHERE land_id IN (#{land_ids.join(',')})").map(&:to_i) : []
      iu_ids    = bld_ids.any?  ? select_values("SELECT id FROM individual_units WHERE building_id IN (#{bld_ids.join(',')})").map(&:to_i) : []

      # Delete deepest dependents first
      rx_cond = [
        (reg_ids.any? ? "registration_id IN (#{reg_ids.join(',')})"  : nil),
        (land_ids.any? ? "land_id IN (#{land_ids.join(',')})"         : nil),
        (bld_ids.any?  ? "building_id IN (#{bld_ids.join(',')})"      : nil),
        (iu_ids.any?   ? "individual_unit_id IN (#{iu_ids.join(',')})" : nil)
      ].compact.join(" OR ")
      execute "DELETE FROM registration_x_entities WHERE #{rx_cond}" if rx_cond.present?

      cx_cond = [
        (land_ids.any? ? "land_id IN (#{land_ids.join(',')})"         : nil),
        (bld_ids.any?  ? "building_id IN (#{bld_ids.join(',')})"      : nil),
        (iu_ids.any?   ? "individual_unit_id IN (#{iu_ids.join(',')})" : nil)
      ].compact.join(" OR ")
      execute "DELETE FROM contested_x_entities WHERE #{cx_cond}" if cx_cond.present?

      execute "DELETE FROM individual_units WHERE building_id IN (#{bld_ids.join(',')})" if bld_ids.any?
      execute "DELETE FROM building_common_parts WHERE building_id IN (#{bld_ids.join(',')})" if bld_ids.any?
      execute "DELETE FROM points WHERE building_id IN (#{bld_ids.join(',')})" if bld_ids.any?
      execute "DELETE FROM points WHERE land_id IN (#{land_ids.join(',')})" if land_ids.any?
      execute "DELETE FROM parcels WHERE land_id IN (#{land_ids.join(',')})" if land_ids.any?
      execute "DELETE FROM buildings WHERE land_id IN (#{land_ids.join(',')})" if land_ids.any?

      execute "DELETE FROM persons WHERE file_description_id IN (#{ids})"
      if reg_ids.any?
        execute "UPDATE persons SET registration_id = NULL WHERE registration_id IN (#{reg_ids.join(',')})"
      end
      execute "DELETE FROM registrations WHERE deed_id IN (#{deed_ids.join(',')})" if deed_ids.any?
      execute "DELETE FROM deeds WHERE file_description_id IN (#{ids})"

      execute "UPDATE lands SET file_description_id = NULL WHERE file_description_id IN (#{ids})"
      execute "DELETE FROM cgxml_validation_errors WHERE file_description_id IN (#{ids})"
      execute "DELETE FROM file_descriptions WHERE id IN (#{ids})"
    end

    add_index :file_descriptions, :filename, unique: true
  end

  def down
    remove_index :file_descriptions, :filename
  end
end
