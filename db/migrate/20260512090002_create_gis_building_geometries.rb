# Cache geometric pentru buildings. Vezi gis_land_geometries pentru rațiune.
class CreateGisBuildingGeometries < ActiveRecord::Migration[8.1]
  def change
    create_table :gis_building_geometries do |t|
      t.bigint :building_id, null: false
      t.column :geom,     "geometry(MultiPolygon, 3844)", null: false
      t.column :centroid, "geometry(Point, 3844)"
      t.decimal :suprafata_mp, precision: 14, scale: 4

      t.string :status, null: false, default: "draft"
      t.string :owner_token
      t.text   :notes

      t.timestamps
    end

    add_foreign_key :gis_building_geometries, :buildings, on_delete: :cascade
    add_index :gis_building_geometries, :building_id, unique: true
    add_index :gis_building_geometries, :geom,     using: :gist
    add_index :gis_building_geometries, :centroid, using: :gist
    add_index :gis_building_geometries, :status
  end
end
