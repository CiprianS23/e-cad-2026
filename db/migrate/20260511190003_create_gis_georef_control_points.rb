class CreateGisGeorefControlPoints < ActiveRecord::Migration[8.0]
  def change
    create_table :gis_georef_control_points do |t|
      t.references :gis_georef_plan, null: false, foreign_key: true, index: true
      t.integer :ordinal,  null: false, default: 0
      t.float   :pixel_x,  null: false  # coord în imaginea sursă (col)
      t.float   :pixel_y,  null: false  # coord în imaginea sursă (row, top-left=0,0)
      t.float   :world_x,  null: false  # coord în EPSG:3844 (m)
      t.float   :world_y,  null: false
      t.float   :residual              # reziduu la fit (m), calculat după georef
      t.string  :note
      t.timestamps
    end

    add_index :gis_georef_control_points, [:gis_georef_plan_id, :ordinal],
              name: "ix_gis_gcp_plan_ord"
  end
end
