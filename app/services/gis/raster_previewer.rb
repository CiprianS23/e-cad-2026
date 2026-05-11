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
    DEFAULT_MAX_DIM  = 4000   # px pe latura lungă; ~1-2 MB JPG pentru scanate
    DEFAULT_QUALITY  = 85     # JPEG quality (1-100); 85 = bun compromis

    # Generează o variantă JPEG mai mică pentru afișare în browser.
    # - Downscale la `max_dim` px pe latura lungă (păstrează raportul)
    # - JPEG quality 85 — bun compromis pentru scanări (mult mai mic decât PNG)
    # - Bilinear resampling pentru aspect plăcut la zoom mediu
    #
    # IMPORTANT: dim originale (W × H) ale rasterului sursă rămân autoritare —
    # frontend-ul afișează preview-ul în coordonate pixel ORIGINALE (OL îl
    # upscalează vizual). Deci coords click-urilor pe preview sunt deja în
    # sistemul original, fără transformare suplimentară necesară.
    def self.to_web_preview(source_path, max_dim: DEFAULT_MAX_DIM, quality: DEFAULT_QUALITY)
      dims = dimensions(source_path)
      return source_path if dims.nil?  # nu putem citi sursa — încercăm direct

      w, h = dims
      long_side = [w, h].max

      stable = Rails.root.join("tmp", "preview_#{SecureRandom.hex(8)}.jpg").to_s
      cmd = ["gdal_translate", "-of", "JPEG", "-co", "QUALITY=#{quality}", "-co", "WORLDFILE=NO"]
      if long_side > max_dim
        scale = max_dim.to_f / long_side
        new_w = (w * scale).round
        new_h = (h * scale).round
        cmd += ["-outsize", new_w.to_s, new_h.to_s, "-r", "bilinear"]
      end
      cmd += [source_path, stable]

      out = `#{cmd.map { |a| Shellwords.escape(a) }.join(' ')} 2>&1`
      raise PreviewError, "gdal_translate eșuat: #{out.lines.last(3).join.strip}" unless $?.success?
      stable
    end

    # Pentru backwards-compat: încă oferim to_png când JPEG nu e potrivit
    # (de ex. necesită canal alfa).
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
