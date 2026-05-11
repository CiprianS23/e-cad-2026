class CreateGisContours < ActiveRecord::Migration[8.1]
  def change
    create_table :gis_contours do |t|
      t.string  :name,        null: false
      t.string  :state,       null: false, default: "open"  # open | finalized
      t.column  :geom,        "geometry(Polygon, 3844)", null: false
      t.decimal :area,        precision: 14, scale: 2
      t.string  :owner_token, null: false
      t.text    :notes

      t.timestamps
    end

    add_index :gis_contours, :geom, using: :gist
    add_index :gis_contours, :owner_token
    add_index :gis_contours, :state
  end
end
