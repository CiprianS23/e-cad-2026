class CreateLands < ActiveRecord::Migration[8.1]
  def change
    create_table :lands do |t|
      t.references :file_description, foreign_key: true
      t.references :address,           foreign_key: true
      t.string  :cadsector,           limit: 200
      t.float   :measuredarea,        default: 0.0, null: false
      t.float   :parcellegalarea
      t.float   :buildinglegalarea
      t.float   :taxvalue
      t.boolean :isnew,               default: true
      t.text    :notes
      t.boolean :enclosed
      t.boolean :coarea
      t.string  :e2identifier,        limit: 200
      t.string  :papercadno,          limit: 200
      t.string  :paperlbno,           limit: 200
      t.string  :topono,              limit: 200
      t.string  :cadgenno,            limit: 200

      t.timestamps
    end
  end
end
