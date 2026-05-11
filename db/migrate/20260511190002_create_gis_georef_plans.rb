class CreateGisGeorefPlans < ActiveRecord::Migration[8.0]
  def change
    create_table :gis_georef_plans do |t|
      t.string  :name,             null: false
      t.text    :description
      t.string  :owner_token,      null: false
      t.integer :original_width
      t.integer :original_height
      t.string  :transform_type    # 'affine' | 'polynomial2'
      t.jsonb   :transform_params  # matrix params; structura depinde de transform_type
      t.string  :state,            null: false, default: "draft"  # draft|georeferenced|finalized
      t.float   :residual_rms      # eroare medie pătratică (m) după fit
      t.timestamps
    end

    # Coloana bounds_geom: poligonul rezultat după warp (proiectat în EPSG:3844)
    execute <<~SQL
      SELECT AddGeometryColumn('public', 'gis_georef_plans', 'bounds_geom', 3844, 'POLYGON', 2);
    SQL

    # Raster opțional (populat când planul e "finalizat" — gdalwarp produce
    # un GeoTIFF care e încărcat în această coloană via raster2pgsql).
    add_column :gis_georef_plans, :raster, :raster

    add_index :gis_georef_plans, :owner_token
    add_index :gis_georef_plans, :state
    add_index :gis_georef_plans, :bounds_geom, using: :gist
  end
end
