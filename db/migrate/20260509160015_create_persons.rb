class CreatePersons < ActiveRecord::Migration[8.1]
  def change
    create_table :persons do |t|
      t.references :address,          foreign_key: true
      t.references :file_description, foreign_key: true
      t.references :registration,     foreign_key: true
      t.string  :firstname,           limit: 255, null: false
      t.boolean :isphysical,          default: true
      t.string  :lastname,            limit: 255
      t.boolean :defunct
      t.boolean :identified
      t.string  :idcode,              limit: 50
      t.string  :previouslastname,    limit: 50
      t.string  :fatherinitial,       limit: 50
      t.string  :citizenshipcountry,  limit: 50
      t.string  :idcardtype,          limit: 50
      t.string  :idcardserialno,      limit: 50
      t.string  :idcardnumber
      t.text    :notes
      t.string  :phone
      t.string  :email

      t.timestamps
    end
  end
end
