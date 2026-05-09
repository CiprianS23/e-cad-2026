class CreatePoints < ActiveRecord::Migration[8.1]
  def change
    create_table :points do |t|
      t.references :land,     foreign_key: true
      t.references :building, foreign_key: true
      t.string  :no,    limit: 50
      t.float   :x
      t.float   :y
      t.st_point :coordinates, srid: 3844, has_z: false

      t.timestamps
    end

    add_index :points, :coordinates, using: :gist
  end
end
