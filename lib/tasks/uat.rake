namespace :uat do
  desc "Importă limitele UAT din Shapefile în uat_boundaries (necesită GDAL/ogr2ogr)"
  task import: :environment do
    shp = Rails.root.join("lib/data/Unitate_administrativa_UAT.shp")

    unless File.exist?(shp)
      zip = Rails.root.join("lib/data/limite_UAT.zip")
      abort "Fișierul #{zip} nu există." unless File.exist?(zip)

      require "tmpdir"
      @tmpdir = Dir.mktmpdir("uat_shp")
      system "unzip -q -o #{zip} -d #{@tmpdir}"
      shp = Dir["#{@tmpdir}/**/Unitate_administrativa_UAT.shp"].first
      abort "Nu am găsit Unitate_administrativa_UAT.shp în arhivă." unless shp
    end

    db   = ActiveRecord::Base.connection_db_config.configuration_hash
    pass = db[:password].to_s
    conn = "PG:\"host=#{db[:host] || 'localhost'} port=#{db[:port] || 5432} " \
           "dbname=#{db[:database]} user=#{db[:username]} password=#{pass}\""

    # SQL to map shapefile columns → Rails table columns
    sql = <<~SQL.squish
      SELECT Id AS shp_id, localId AS local_id, natLevel AS nat_level,
             natLevName AS nat_lev_name, natCode AS nat_code, name,
             resOfAut AS res_of_aut, beginVers AS begin_vers,
             endVersion AS end_version, Shape_Leng AS shape_leng,
             Shape_Area AS shape_area, geometry
      FROM Unitate_administrativa_UAT
    SQL

    cmd = [
      "ogr2ogr",
      "-f", "PostgreSQL", conn,
      shp,
      "-nln", "uat_boundaries",
      "-nlt", "MULTIPOLYGON",
      "-lco", "GEOMETRY_NAME=geom",
      "-lco", "FID=id",
      "-lco", "PRECISION=NO",
      "-a_srs", "EPSG:3844",
      "-append",
      "--config", "PG_USE_COPY", "YES"
    ].join(" ")

    puts "Import UAT din: #{shp}"
    UatBoundary.delete_all

    # ogr2ogr doesn't support SELECT rename easily, use Python/psycopg2 fallback
    # Instead, load via ogr2ogr into a temp table then INSERT SELECT
    tmp_table = "uat_boundaries_tmp_#{Time.now.to_i}"
    conn_str  = "PG:\"host=#{db[:host] || 'localhost'} port=#{db[:port] || 5432} " \
                "dbname=#{db[:database]} user=#{db[:username]} password=#{pass}\""

    ogr_cmd = "ogr2ogr -f PostgreSQL #{conn_str} " \
              "\"#{shp}\" " \
              "-nln #{tmp_table} " \
              "-nlt MULTIPOLYGON " \
              "-lco GEOMETRY_NAME=geom " \
              "-lco FID=ogc_fid " \
              "-lco PRECISION=NO " \
              "-a_srs EPSG:3844 " \
              "--config PG_USE_COPY YES"

    system(ogr_cmd) or abort "ogr2ogr a eșuat."

    conn_obj = ActiveRecord::Base.connection
    conn_obj.execute(<<~SQL)
      INSERT INTO uat_boundaries
        (shp_id, local_id, nat_level, nat_lev_name, nat_code, name,
         res_of_aut, begin_vers, end_version, shape_leng, shape_area, geom)
      SELECT
        id::bigint, localid, natlevel, natlevname, natcode, name,
        resofaut, beginvers, endversion,
        shape_leng::float, shape_area::float,
        geom
      FROM #{tmp_table}
    SQL

    conn_obj.execute("DROP TABLE IF EXISTS #{tmp_table}")
    puts "UAT: #{UatBoundary.count} limite importate."
  ensure
    FileUtils.remove_entry(@tmpdir) if defined?(@tmpdir) && @tmpdir
  end
end
