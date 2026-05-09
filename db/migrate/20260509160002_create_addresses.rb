class CreateAddresses < ActiveRecord::Migration[8.1]
  def change
    create_table :addresses do |t|
      t.string  :sirsup,       limit: 50
      t.string  :siruta,       limit: 50
      t.boolean :intravilan,   default: false
      t.string  :districttype, limit: 50
      t.string  :districtname, limit: 50
      t.string  :streettype,   limit: 50
      t.string  :streetname,   limit: 50
      t.string  :postalnumber, limit: 50
      t.string  :block,        limit: 50
      t.string  :entry,        limit: 50
      t.string  :floor,        limit: 50
      t.string  :apno,         limit: 50
      t.string  :zipcode,      limit: 50
      t.text    :description
      t.string  :section,      limit: 100

      t.timestamps
    end
  end
end
