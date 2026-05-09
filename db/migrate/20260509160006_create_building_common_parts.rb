class CreateBuildingCommonParts < ActiveRecord::Migration[8.1]
  def change
    create_table :building_common_parts do |t|
      t.references :building, foreign_key: true
      t.string :commonparttype, limit: 255

      t.timestamps
    end
  end
end
