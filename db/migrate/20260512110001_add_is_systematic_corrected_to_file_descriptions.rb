# Flag pe FileDescription pentru a distinge fișierele cgxml „corectate" (livrabile
# finale de cadastru sistematic) de cele „sporadic" (export OCPI cu date variabile).
# Folosit pentru:
#   1. Filtrare în UI (badge „Corectat" vs „Sporadic")
#   2. Analiză comparativă a regulilor de validare (reguli care nu se aplică pe
#      cele corectate = false positives → relax; reguli care se aplică doar pe
#      sporadic = signal real → keep)
class AddIsSystematicCorrectedToFileDescriptions < ActiveRecord::Migration[8.1]
  def change
    add_column :file_descriptions, :is_systematic_corrected, :boolean, null: false, default: false
    add_index  :file_descriptions, :is_systematic_corrected
  end
end
