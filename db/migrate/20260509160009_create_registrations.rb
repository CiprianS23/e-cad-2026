class CreateRegistrations < ActiveRecord::Migration[8.1]
  def change
    create_table :registrations do |t|
      t.references :deed, null: false, foreign_key: true
      t.string  :registrationtype, null: false
      t.string  :righttype,        limit: 50
      t.text    :rightcomment
      t.text    :notes
      t.string  :title,            limit: 50
      t.string  :quotatype,        limit: 50
      t.string  :initialquota,     limit: 50
      t.string  :actualquota,      limit: 50
      t.string  :valuecurrency,    limit: 50
      t.string  :valueamount,      limit: 50
      t.text    :comments
      t.integer :lbpartno
      t.integer :position
      t.integer :appno
      t.datetime :appdate

      t.timestamps
    end
  end
end
