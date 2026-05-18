require "yaml"

# Afișează jurnalul funcțional al aplicației (descrieri pentru utilizatori,
# nu detalii tehnice). Sursă: `data/jurnal_functional.yml`. Sortare:
# inversă-cronologică (cele mai recente primele). Detaliile funcțiunilor sunt
# expandabile via `<details>` HTML.
class JurnalModificariController < ApplicationController
  JOURNAL_PATH = Rails.root.join("data", "jurnal_functional.yml").freeze

  def show
    if File.exist?(JOURNAL_PATH)
      raw = YAML.load_file(JOURNAL_PATH, permitted_classes: [Date, Time]) || []
      # Sort: data descrescător (cele mai recente sus); pentru aceeași dată,
      # păstrăm ordinea din fișier (idx ASC) — convenția noastră adaugă noua
      # intrare la TOP, deci cea mai nouă rămâne mereu prima.
      @entries = raw.each_with_index
                    .sort_by { |e, idx| [-parse_entry_date(e["date"]).to_time.to_i, idx] }
                    .map(&:first)
      @file_mtime = File.mtime(JOURNAL_PATH)
    else
      @entries = []
      @file_mtime = nil
    end
  end

  private

  def parse_entry_date(value)
    return value if value.is_a?(Date)
    return value.to_date if value.is_a?(Time)
    Date.parse(value.to_s) rescue Date.new(1900, 1, 1)
  end
end
