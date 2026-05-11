class CreateGisUserLayerGroups < ActiveRecord::Migration[8.0]
  # Grupuri configurabile de utilizator pentru Layer Manager (QGIS-like).
  # Permite organizarea layerelor în foldere colapsibile pentru a reduce
  # spațiul ocupat în panou când ai mulți layeri (mai ales cu planuri raster).
  #
  # Convenții:
  # - `owner_token` = aceeași cheie ca pe `gis_user_layer_prefs` (cookie semnat)
  # - `position` = ordinea verticală în panou (asc); recalculată la drag&drop
  # - `collapsed` = stare expand/collapse persistată per user
  # - Layerele cu `group_id IS NULL` apar într-o secțiune „Layere ungrouped"
  def change
    create_table :gis_user_layer_groups do |t|
      t.string  :owner_token, null: false
      t.string  :name,        null: false, limit: 100
      t.integer :position,    null: false, default: 0
      t.boolean :collapsed,   default: false
      t.timestamps
    end
    add_index :gis_user_layer_groups, [:owner_token, :position]

    add_reference :gis_user_layer_prefs, :group,
                  foreign_key: { to_table: :gis_user_layer_groups, on_delete: :nullify },
                  null: true,
                  index: true
  end
end
