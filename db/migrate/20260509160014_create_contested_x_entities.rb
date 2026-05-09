class CreateContestedXEntities < ActiveRecord::Migration[8.1]
  def change
    create_table :contested_x_entities do |t|
      t.references :contested,       foreign_key: true
      t.references :land,            foreign_key: true
      t.references :building,        foreign_key: true
      t.references :individual_unit, foreign_key: true

      t.timestamps
    end
  end
end
