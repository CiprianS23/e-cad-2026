class CreateUatBoundaries < ActiveRecord::Migration[8.0]
  def up
    # Table may already exist from a direct ogr2ogr import; drop and recreate
    # to ensure Rails-managed schema with correct column names and indexes.
    drop_table :uat_boundaries, if_exists: true

    create_table :uat_boundaries do |t|
      t.bigint  :shp_id                       # original shapefile Id field
      t.string  :local_id,    limit: 254
      t.string  :nat_level,   limit: 254
      t.string  :nat_lev_name, limit: 254
      t.string  :nat_code,    limit: 254
      t.string  :name,        limit: 254
      t.string  :res_of_aut,  limit: 254
      t.date    :begin_vers
      t.date    :end_version
      t.float   :shape_leng
      t.float   :shape_area
      t.multi_polygon :geom, srid: 3844
    end

    add_index :uat_boundaries, :nat_code
    add_index :uat_boundaries, :name
    add_index :uat_boundaries, :geom, using: :gist
  end

  def down
    drop_table :uat_boundaries
  end
end
