class CreateSirutaUats < ActiveRecord::Migration[8.0]
  def change
    create_table :siruta_uats do |t|
      t.integer :cod_siruta,     null: false
      t.integer :cod_judet,      null: false
      t.string  :denumire_judet, null: false, limit: 60
      t.integer :tip_uat,        null: false
      t.string  :tip_uat_abrev,  null: false, limit: 4
      t.string  :denumire_uat,   null: false, limit: 100
    end

    add_index :siruta_uats, :cod_siruta, unique: true
    add_index :siruta_uats, :cod_judet
    add_index :siruta_uats, :denumire_uat
  end
end
