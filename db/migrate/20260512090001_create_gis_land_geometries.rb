# Cache geometric pentru lands. Geometria canonică în cgxml stă în `points` (vertecșii),
# dar query-urile spațiale interactive (overlap, intersect, audit topologic) sunt prea
# lente reconstruind poligonul on-the-fly. Această tabelă stochează MultiPolygon-ul
# indexat GIST, sincronizat cu points la save. NU modifică schema e-CAD existentă.
class CreateGisLandGeometries < ActiveRecord::Migration[8.1]
  def change
    create_table :gis_land_geometries do |t|
      t.bigint :land_id, null: false
      t.column :geom,     "geometry(MultiPolygon, 3844)", null: false
      t.column :centroid, "geometry(Point, 3844)"
      t.decimal :suprafata_mp, precision: 14, scale: 4

      # 'draft' = digitizat local, fără informații juridice;
      # 'active' = imobil cu registrations + persons + deeds atașate.
      t.string :status, null: false, default: "draft"

      t.string :owner_token  # placeholder pentru ownership multi-user la digitizare
      t.text   :notes

      t.timestamps
    end

    add_foreign_key :gis_land_geometries, :lands, on_delete: :cascade
    add_index :gis_land_geometries, :land_id, unique: true
    add_index :gis_land_geometries, :geom,     using: :gist
    add_index :gis_land_geometries, :centroid, using: :gist
    add_index :gis_land_geometries, :status
  end
end
