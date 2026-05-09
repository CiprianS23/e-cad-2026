class CreateBuildings < ActiveRecord::Migration[8.1]
  def change
    create_table :buildings do |t|
      t.references :land,    null: false, foreign_key: true
      t.references :address, foreign_key: true
      t.integer :buildno,           null: false
      t.float   :measuredarea,      default: 0.0
      t.float   :totalarea,         default: 0.0
      t.string  :buildingdestination, limit: 50
      t.integer :levelsno
      t.integer :iuno,              default: 0
      t.float   :taxvalue
      t.text    :notes
      t.boolean :islegal,           default: true, null: false
      t.float   :legalarea
      t.string  :e2identifier,      limit: 200
      t.string  :papercadno,        limit: 200
      t.string  :paperlbno,         limit: 200
      t.string  :topono,            limit: 200
      t.string  :cadgenno,          limit: 200

      t.timestamps
    end
  end
end
