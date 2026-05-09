class CreateFileDescriptions < ActiveRecord::Migration[8.1]
  def change
    create_table :file_descriptions do |t|
      t.string  :filename,      limit: 50,  null: false
      t.datetime :exportdate
      t.string  :fileversion,   limit: 50
      t.string  :operationtype, limit: 50
      t.string  :licensedname,  limit: 255
      t.string  :licensenumber, limit: 50

      t.timestamps
    end
  end
end
