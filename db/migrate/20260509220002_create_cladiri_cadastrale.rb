class CreateCladiriCadastrale < ActiveRecord::Migration[8.1]
  def change
    create_table :cladiri_cadastrale do |t|
      t.string  :numar_cadastral,         null: false
      t.string  :destinatie
      t.string  :regim_inaltime
      t.decimal :suprafata_construita_mp, precision: 12, scale: 4
      t.string  :judet,                   null: false
      t.string  :localitate,              null: false
      t.string  :proprietar
      t.string  :status,                  null: false, default: "activ"
      t.multi_polygon :geom,    srid: 3844
      t.st_point      :centroid, srid: 3844
      t.timestamps
    end

    add_index :cladiri_cadastrale, :numar_cadastral, unique: true
    add_index :cladiri_cadastrale, :judet
    add_index :cladiri_cadastrale, :status
    add_index :cladiri_cadastrale, :geom,     using: :gist
    add_index :cladiri_cadastrale, :centroid, using: :gist
  end
end
