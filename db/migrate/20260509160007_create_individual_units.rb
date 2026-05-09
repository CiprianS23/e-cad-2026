class CreateIndividualUnits < ActiveRecord::Migration[8.1]
  def change
    create_table :individual_units do |t|
      t.references :building, foreign_key: true
      t.string  :identifier,        limit: 50,   null: false
      t.string  :section,           limit: 50
      t.string  :apno,              limit: 50
      t.string  :entry,             limit: 50
      t.float   :measuredarea
      t.float   :totalarea
      t.string  :landindivisionarea
      t.string  :commonpartsarea
      t.text    :notes
      t.string  :floor,             limit: 50
      t.string  :landdivisiontype
      t.string  :commonpartstype
      t.integer :roomno
      t.string  :e2identifier,      limit: 200
      t.string  :papercadno,        limit: 200
      t.string  :paperlbno,         limit: 200
      t.string  :topono,            limit: 200
      t.string  :cadgenno,          limit: 200

      t.timestamps
    end
  end
end
