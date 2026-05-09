class ChangeParceleCadastraleToSrid3844 < ActiveRecord::Migration[8.1]
  def up
    remove_index  :parcele_cadastrale, :centroid
    remove_column :parcele_cadastrale, :centroid

    add_column :parcele_cadastrale, :centroid, :st_point, srid: 3844, has_z: false
    add_index  :parcele_cadastrale, :centroid, using: :gist
  end

  def down
    remove_index  :parcele_cadastrale, :centroid
    remove_column :parcele_cadastrale, :centroid

    add_column :parcele_cadastrale, :centroid, :st_point, srid: 4326, geographic: true
    add_index  :parcele_cadastrale, :centroid, using: :gist
  end
end
