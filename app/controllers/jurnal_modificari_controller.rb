require "kramdown"

# Afișează `2_jurnal_modificari.md` ca pagină HTML. Conținutul e markdown
# (sesiuni cronologice cu modificările), randat cu Kramdown.
class JurnalModificariController < ApplicationController
  JOURNAL_PATH = Rails.root.join("2_jurnal_modificari.md").freeze

  def show
    if File.exist?(JOURNAL_PATH)
      md = File.read(JOURNAL_PATH)
      @html      = Kramdown::Document.new(md, input: "kramdown", auto_ids: true, syntax_highlighter: nil).to_html.html_safe
      @file_mtime = File.mtime(JOURNAL_PATH)
    else
      @html = "<p><em>Fișierul jurnal nu există în repo.</em></p>".html_safe
      @file_mtime = nil
    end
  end
end
