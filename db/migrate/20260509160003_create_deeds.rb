class CreateDeeds < ActiveRecord::Migration[8.1]
  def change
    create_table :deeds do |t|
      t.references :file_description, null: false, foreign_key: true
      t.string  :deednumber,     limit: 200, null: false
      t.datetime :deeddate
      t.string  :deedtype,       limit: 255, null: false
      t.string  :authority,      limit: 50,  null: false
      t.text    :notes
      t.string  :valuecurrency,  limit: 50
      t.string  :valueamount,    limit: 200

      t.timestamps
    end
  end
end
