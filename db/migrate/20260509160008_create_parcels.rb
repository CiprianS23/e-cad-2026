class CreateParcels < ActiveRecord::Migration[8.1]
  def change
    create_table :parcels do |t|
      t.references :land, foreign_key: true
      t.integer :number
      t.float   :measuredarea
      t.string  :usecategory,  limit: 50
      t.boolean :intravilan
      t.float   :taxvalue
      t.string  :titleno,      limit: 50
      t.string  :landplotno,   limit: 50
      t.string  :parcelno,     limit: 50
      t.text    :notes
      t.string  :e2identifier, limit: 200
      t.string  :papercadno,   limit: 200
      t.string  :paperlbno,    limit: 200
      t.string  :topono,       limit: 200
      t.string  :cadgenno,     limit: 200

      t.timestamps
    end
  end
end
