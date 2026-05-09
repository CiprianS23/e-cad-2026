class CreateRegistrationXEntities < ActiveRecord::Migration[8.1]
  def change
    create_table :registration_x_entities do |t|
      t.references :registration,    foreign_key: true
      t.references :land,            foreign_key: true
      t.references :building,        foreign_key: true
      t.references :individual_unit, foreign_key: true

      t.timestamps
    end

    add_index :registration_x_entities, [ :registration_id, :land_id ],            name: "idx_reg_x_ent_reg_land"
    add_index :registration_x_entities, [ :registration_id, :building_id ],        name: "idx_reg_x_ent_reg_bld"
    add_index :registration_x_entities, [ :registration_id, :individual_unit_id ], name: "idx_reg_x_ent_reg_iu"
  end
end
