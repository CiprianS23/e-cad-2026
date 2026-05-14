# Tabele paralele de digitizare locală, redundante cu lands+gis_land_geometries
# și buildings+gis_building_geometries (modelul unificat „imobil grafic").
# La momentul drop-ului erau goale (0 rânduri).
class DropParceleCadastraleAndCladiriCadastrale < ActiveRecord::Migration[8.1]
  def up
    drop_table :cladiri_cadastrale
    drop_table :parcele_cadastrale
  end

  def down
    create_table :parcele_cadastrale do |t|
      t.string  :numar_cadastral,     null: false
      t.string  :numar_topografic
      t.string  :categoria_folosinta, null: false
      t.decimal :suprafata_mp, precision: 12, scale: 4
      t.string  :judet,      null: false
      t.string  :localitate, null: false
      t.string  :adresa
      t.string  :proprietar
      t.string  :cnp_cui_proprietar
      t.string  :status, null: false, default: "activ"
      t.column  :geom,     "geometry(MultiPolygon, 3844)"
      t.column  :centroid, "geometry(Point, 3844)"
      t.timestamps
    end
    add_index :parcele_cadastrale, :numar_cadastral, unique: true
    add_index :parcele_cadastrale, :geom,     using: :gist
    add_index :parcele_cadastrale, :centroid, using: :gist
    add_index :parcele_cadastrale, :judet
    add_index :parcele_cadastrale, :status

    create_table :cladiri_cadastrale do |t|
      t.references :parcela_cadastrala, foreign_key: true
      t.string  :numar_cadastral, null: false
      t.string  :destinatie
      t.string  :regim_inaltime
      t.decimal :suprafata_construita_mp, precision: 12, scale: 4
      t.string  :judet,      null: false
      t.string  :localitate, null: false
      t.string  :proprietar
      t.string  :status, null: false, default: "activ"
      t.column  :geom,     "geometry(MultiPolygon, 3844)"
      t.column  :centroid, "geometry(Point, 3844)"
      t.timestamps
    end
    add_index :cladiri_cadastrale, :numar_cadastral, unique: true
    add_index :cladiri_cadastrale, :geom,     using: :gist
    add_index :cladiri_cadastrale, :centroid, using: :gist
  end
end
