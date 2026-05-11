class EnablePostgisRaster < ActiveRecord::Migration[8.0]
  # Activează extensia PostGIS Raster — folosită pentru stocarea rasterelor
  # georeferențiate (planuri vechi) ca obiecte `raster` native în DB.
  # Schema e-CAD existentă NU folosește această extensie, deci activarea ei
  # e o adăugare strict pentru modulul GIS.
  def up
    enable_extension "postgis_raster" unless extension_enabled?("postgis_raster")
  end

  def down
    # Nu dezactivăm — extensia poate fi folosită de tabele rămase după rollback.
  end
end
