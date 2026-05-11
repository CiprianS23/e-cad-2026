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

    # Generează o variantă JPEG (sau PNG fallback) pentru afișare în browser.
    # - Detectează benzi și tipul de date din sursă (gdalinfo)
    # - JPEG: necesită Byte + 1 sau 3 benzi → adăugăm `-ot Byte -scale` și
    #   `-b 1 -b 2 -b 3` când e cazul (drop alpha sau benzi suplimentare)
    # - Dacă JPEG eșuează (configurare neobișnuită), fallback la PNG
    # - Downscale la `max_dim` px pe latura lungă
    #
    # IMPORTANT: dim originale (W × H) ale rasterului sursă rămân autoritare —
    # frontend-ul afișează preview-ul în coordonate pixel ORIGINALE (OL îl
    # upscalează vizual). Coords click pe preview = sistem original.
    def self.to_web_preview(source_path, max_dim: DEFAULT_MAX_DIM, quality: DEFAULT_QUALITY)
      info = gdalinfo_json(source_path)
      return source_path unless info

      w          = info["size"]&.[](0)    || info["rasterXSize"]
      h          = info["size"]&.[](1)    || info["rasterYSize"]
      bands      = info["bands"] || []
      band_count = bands.length
      data_type  = bands[0]&.[]("type") || "Byte"
      long_side  = [w, h].max
      return source_path if w.nil? || h.nil?

      outsize_args = []
      if long_side > max_dim
        scale = max_dim.to_f / long_side
        outsize_args = ["-outsize", (w * scale).round.to_s, (h * scale).round.to_s, "-r", "bilinear"]
      end

      # Încercare 1: JPEG (mic, ideal pentru scanări)
      jpg_path = try_gdal_translate(
        source_path, ".jpg",
        ["-of", "JPEG", "-co", "QUALITY=#{quality}", "-co", "WORLDFILE=NO"] +
          jpeg_band_args(band_count, data_type) +
          outsize_args
      )
      return jpg_path if jpg_path

      # Fallback: PNG (acceptă orice configurare de benzi)
      png_path = try_gdal_translate(
        source_path, ".png",
        ["-of", "PNG", "-co", "WORLDFILE=NO"] +
          png_type_args(data_type) +
          outsize_args
      )
      return png_path if png_path

      raise PreviewError, "Nu pot genera preview cu gdal_translate (nici JPEG, nici PNG)"
    end

    # Construiește argumentele specifice JPEG pentru gdal_translate, în funcție
    # de configurarea sursei (drop alpha, scale to byte).
    def self.jpeg_band_args(band_count, data_type)
      args = []
      args += ["-ot", "Byte", "-scale"] if data_type != "Byte"
      args += ["-b", "1", "-b", "2", "-b", "3"] if band_count >= 3
      # 1 sau 2 benzi: GDAL le tratează implicit (grayscale)
      args
    end

    def self.png_type_args(data_type)
      data_type != "Byte" ? ["-ot", "Byte", "-scale"] : []
    end

    def self.try_gdal_translate(source_path, ext, args)
      stable = Rails.root.join("tmp", "preview_#{SecureRandom.hex(8)}#{ext}").to_s
      cmd    = ["gdal_translate", *args, source_path, stable]
      out    = `#{cmd.map { |a| Shellwords.escape(a) }.join(' ')} 2>&1`
      if $?.success? && File.exist?(stable) && File.size(stable) > 0
        Rails.logger.info "RasterPreviewer: generat #{stable} (#{File.size(stable)} bytes)"
        stable
      else
        Rails.logger.warn "RasterPreviewer: try_gdal_translate(#{ext}) eșuat: #{out.lines.last(3).join.strip}"
        File.delete(stable) if File.exist?(stable)
        nil
      end
    end

    def self.gdalinfo_json(source_path)
      out = `gdalinfo -json #{Shellwords.escape(source_path)} 2>/dev/null`
      return nil unless $?.success?
      JSON.parse(out)
    rescue JSON::ParserError
      nil
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
      info = gdalinfo_json(source_path)
      return nil unless info
      size = info["size"] || [info["rasterXSize"], info["rasterYSize"]].compact
      return nil if size.size < 2
      size.map(&:to_i)
    end
  end
end
