class CreateGisImobile < ActiveRecord::Migration[8.1]
  def change
    create_table :gis_imobile do |t|
      # Sursa CGXML — opțional; imobile complet noi (din parcelare) au NULL
      t.bigint :land_id

      # Placeholder pentru proiect divizare; legătura formală vine mai târziu.
      t.bigint :proiect_divizare_id

      # Geometria după constrângere/parcelare; SRID 3844 (Stereo70)
      t.column :geom_corrected, "geometry(MultiPolygon, 3844)"

      # Aria în mp (calculată de PostGIS la INSERT/UPDATE printr-un before_save)
      t.decimal :area_corrected, precision: 14, scale: 2

      # Sursa logică a corecției — discrimineaz`ă fluxul: clip CGXML, divizare zonă, etc.
      t.string :source, null: false, default: "cgxml_fit"

      # Audit
      t.datetime :corrected_at, default: -> { "CURRENT_TIMESTAMP" }
      t.string   :corrected_by  # placeholder; vom lega la user la integrare

      t.timestamps
    end

    add_index :gis_imobile, :land_id
    add_index :gis_imobile, :proiect_divizare_id
    add_index :gis_imobile, :geom_corrected, using: :gist
    add_index :gis_imobile, :source
  end
end
