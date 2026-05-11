class AddBgTransparentToGisUserLayerPrefs < ActiveRecord::Migration[8.0]
  # Pentru layere raster (georef_plan_*): permite utilizatorului să elimine
  # fundalul alb din scanare, astfel încât să rămână vizibile doar liniile/
  # textul desenat. Implementat client-side (pixel filter pe canvas), dar
  # preferința e persistată per utilizator aici.
  def change
    add_column :gis_user_layer_prefs, :bg_transparent, :boolean, default: nil
  end
end
