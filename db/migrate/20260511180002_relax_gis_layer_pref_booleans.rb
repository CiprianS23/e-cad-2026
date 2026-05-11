class RelaxGisLayerPrefBooleans < ActiveRecord::Migration[8.0]
  # Permite NULL pe coloanele booleene + opacity. NULL = "folosește default-ul
  # din `GisUserLayerPref::DEFAULTS`" — necesar pentru că default-urile diferă
  # per layer (ex: uat e blocat, parcele nu) și nu pot fi exprimate ca DEFAULT
  # SQL unic pe coloană.
  def up
    change_column_null    :gis_user_layer_prefs, :visible,           true
    change_column_null    :gis_user_layer_prefs, :locked,            true
    change_column_null    :gis_user_layer_prefs, :opacity,           true
    change_column_null    :gis_user_layer_prefs, :color_by_category, true
    change_column_default :gis_user_layer_prefs, :visible,           from: true,  to: nil
    change_column_default :gis_user_layer_prefs, :locked,            from: false, to: nil
    change_column_default :gis_user_layer_prefs, :opacity,           from: 1.0,   to: nil
    change_column_default :gis_user_layer_prefs, :color_by_category, from: false, to: nil
  end

  def down
    change_column_default :gis_user_layer_prefs, :visible,           from: nil, to: true
    change_column_default :gis_user_layer_prefs, :locked,            from: nil, to: false
    change_column_default :gis_user_layer_prefs, :opacity,           from: nil, to: 1.0
    change_column_default :gis_user_layer_prefs, :color_by_category, from: nil, to: false
    change_column_null    :gis_user_layer_prefs, :visible,           false
    change_column_null    :gis_user_layer_prefs, :locked,            false
    change_column_null    :gis_user_layer_prefs, :opacity,           false
    change_column_null    :gis_user_layer_prefs, :color_by_category, false
  end
end
