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
      @entries = raw.sort_by { |e| e["date"].to_s }.reverse
      @file_mtime = File.mtime(JOURNAL_PATH)
    else
      @entries = []
      @file_mtime = nil
    end
  end
end
