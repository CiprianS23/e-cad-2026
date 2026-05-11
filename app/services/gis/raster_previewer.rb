require "shellwords"
require "tmpdir"
require "fileutils"
require "json"

# Convertește un raster oarecare (TIFF/PDF/etc.) la PNG pentru afișare în
# browser. Browser-ele nu suportă nativ TIFF, deci în pagina de georeferențiere
# avem nevoie de o variantă PNG/JPG a sursei.
#
# Folosește GDAL (gdal_translate -of PNG). Pentru imagini deja PNG/JPG/GIF,
# întoarce path-ul original fără modificări.
#
# De asemenea expune `dimensions(path)` care întoarce [width, height] pentru
# orice raster suportat de GDAL.
module Gis
  class RasterPreviewer
    class PreviewError < StandardError; end

    BROWSER_FORMATS = %w[.png .jpg .jpeg .gif .webp].freeze

    # Returnează un path la o variantă PNG a sursei. Caller-ul e responsabil de
    # ștergerea fișierului (sau îl atașează ca Active Storage și îl uită).
    def self.to_png(source_path)
      ext = File.extname(source_path).downcase
      return source_path if BROWSER_FORMATS.include?(ext)

      stable = Rails.root.join("tmp", "preview_#{SecureRandom.hex(8)}.png").to_s
      cmd = ["gdal_translate", "-of", "PNG", "-co", "WORLDFILE=NO", source_path, stable]
      out = `#{cmd.map { |a| Shellwords.escape(a) }.join(' ')} 2>&1`
      raise PreviewError, "gdal_translate eșuat: #{out.lines.last(3).join.strip}" unless $?.success?
      stable
    end

    # Citește dimensiunile (width, height) ale unui raster prin gdalinfo.
    def self.dimensions(source_path)
      out = `gdalinfo -json #{Shellwords.escape(source_path)} 2>/dev/null`
      return nil unless $?.success?
      info = JSON.parse(out)
      size = info["size"] || [info["rasterXSize"], info["rasterYSize"]].compact
      return nil if size.size < 2
      size.map(&:to_i)
    rescue JSON::ParserError
      nil
    end
  end
end
