class CreateParceleCadastrale < ActiveRecord::Migration[8.1]
  def change
    create_table :parcele_cadastrale do |t|
      t.string  :numar_cadastral,     null: false
      t.string  :numar_topografic
      t.string  :categoria_folosinta, null: false
      t.decimal :suprafata_mp,        precision: 12, scale: 4
      t.string  :judet,               null: false
      t.string  :localitate,          null: false
      t.string  :adresa
      t.string  :proprietar
      t.string  :cnp_cui_proprietar
      t.string  :status,              default: "activ", null: false

      # Geometrie principală — polygon în sistemul de coordonate Stereo 70 (SRID 3844)
      t.multi_polygon :geom, srid: 3844, has_z: false
      # Centroid pentru afișare rapidă pe hartă
      t.st_point :centroid, srid: 4326, geographic: true

      t.timestamps
    end

    add_index :parcele_cadastrale, :numar_cadastral, unique: true
    add_index :parcele_cadastrale, :judet
    add_index :parcele_cadastrale, :status
    add_index :parcele_cadastrale, :geom,     using: :gist
    add_index :parcele_cadastrale, :centroid, using: :gist
  end
end
