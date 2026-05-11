class CreateGisUserLayerPrefs < ActiveRecord::Migration[8.0]
  def change
    create_table :gis_user_layer_prefs do |t|
      t.string  :owner_token, null: false
      t.string  :layer_key,   null: false
      t.boolean :visible,        null: false, default: true
      t.boolean :locked,         null: false, default: false
      t.float   :opacity,        null: false, default: 1.0
      t.string  :stroke_color
      t.string  :fill_color
      t.float   :stroke_width
      t.string  :stroke_dash
      t.integer :z_index
      t.boolean :color_by_category, null: false, default: false
      t.float   :min_resolution
      t.float   :max_resolution

      t.timestamps
    end

    add_index :gis_user_layer_prefs, [:owner_token, :layer_key], unique: true,
              name: "ix_gis_user_layer_prefs_owner_key"
    add_index :gis_user_layer_prefs, :owner_token
  end
end
