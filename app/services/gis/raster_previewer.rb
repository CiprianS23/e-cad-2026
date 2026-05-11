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
    DEFAULT_MAX_DIM  = 6000   # px pe latura lungă; pentru zoom mai detaliat
    DEFAULT_QUALITY  = 92     # JPEG quality (1-100); 92 = scanări claritate ridicată

    # Generează o variantă JPEG sau PNG pentru afișare în browser.
    # - `preserve_alpha: true` → forțează PNG (păstrează canalul alpha pentru
    #   imagini cu zone transparente, e.g. warped GeoTIFF). PNG la 6000px e
    #   ~1MB, încărcare acceptabilă în browser.
    # - Default (alpha nu contează) → încearcă JPEG (mai mic, mai rapid),
    #   fallback PNG.
    def self.to_web_preview(source_path, max_dim: DEFAULT_MAX_DIM, quality: DEFAULT_QUALITY, preserve_alpha: false)
      info = gdalinfo_json(source_path)
      raise PreviewError, "gdalinfo nu poate citi #{source_path}" unless info

      w          = info["size"]&.[](0) || info["rasterXSize"]
      h          = info["size"]&.[](1) || info["rasterYSize"]
      bands      = info["bands"] || []
      band_count = bands.length
      data_type  = bands[0]&.[]("type") || "Byte"
      color_interp = bands[0]&.[]("colorInterpretation")
      has_alpha    = bands.any? { |b| b["colorInterpretation"] == "Alpha" }
      long_side  = [w, h].max
      raise PreviewError, "dimensiuni invalide w=#{w} h=#{h}" if w.nil? || h.nil?

      Rails.logger.info "RasterPreviewer: src=#{source_path} w=#{w} h=#{h} bands=#{band_count} type=#{data_type} color=#{color_interp.inspect} alpha=#{has_alpha}"

      outsize_args = []
      if long_side > max_dim
        scale = max_dim.to_f / long_side
        outsize_args = ["-outsize", (w * scale).round.to_s, (h * scale).round.to_s, "-r", "bilinear"]
      end

      expand_args = color_interp == "Palette" ? ["-expand", "rgb"] : []

      # Pentru imagini cu alpha (warped GeoTIFFs) → PNG direct, ca margins
      # transparente să rămână transparente (nu să devină negru sub JPEG).
      if preserve_alpha || has_alpha
        png_path = try_gdal_translate(
          source_path, ".png",
          ["-of", "PNG", "-co", "WORLDFILE=NO"] +
            (color_interp == "Palette" ? ["-expand", "rgba"] : []) +
            png_type_args(data_type) +
            outsize_args
        )
        return png_path if png_path
      end

      # Drum standard pentru imagini fără alpha: JPEG (mic), fallback PNG.
      jpg_path = try_gdal_translate(
        source_path, ".jpg",
        ["-of", "JPEG", "-co", "QUALITY=#{quality}", "-co", "WORLDFILE=NO"] +
          expand_args +
          jpeg_band_args(band_count, data_type, color_interp) +
          outsize_args
      )
      return jpg_path if jpg_path

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
    # de configurarea sursei (drop alpha, scale to byte, palette expand handled
    # separately by caller).
    def self.jpeg_band_args(band_count, data_type, color_interp = nil)
      args = []
      args += ["-ot", "Byte", "-scale"] if data_type != "Byte"
      # După -expand rgb palette → 3 benzi
      effective_bands = color_interp == "Palette" ? 3 : band_count
      args += ["-b", "1", "-b", "2", "-b", "3"] if effective_bands >= 3
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
