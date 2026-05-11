require "shellwords"
require "tmpdir"
require "json"

# Warp un raster sursă (orice format suportat de GDAL) folosind o listă de
# puncte de control GCP în EPSG:3844. Produce un GeoTIFF georeferențiat în
# Stereo70, pregătit pentru afișare ca `ol.source.ImageStatic` peste harta
# principală sau pentru încărcare ulterioară în PostGIS raster.
#
# Pipeline:
#   1. `gdal_translate -gcp px py wx wy ... -of VRT source.<ext> tmp.vrt`
#   2. `gdalwarp -t_srs EPSG:3844 -r bilinear -order <N> tmp.vrt warped.tif`
#   3. `gdalinfo -json warped.tif` → bounds + dimensiuni
#
# `order`:
#   - 1 = afină (minim 3 GCP-uri)
#   - 2 = polinomială grad 2 (minim 6 GCP-uri, corectează distorsiuni)
#   - 3 = polinomială grad 3 (minim 10 GCP-uri, corectează distorsiuni puternice)
#   - "tps" = thin-plate spline (orice nr ≥ 3, exact prin fiecare GCP — util când
#     vrei să nu deviezi de la GCP-uri dar accepți distorsiuni "valuri")
module Gis
  class RasterWarper
    REQUIRED_BIN = %w[gdal_translate gdalwarp gdalinfo].freeze

    Result = Struct.new(:warped_path, :bounds_3844, :width, :height, :method, keyword_init: true)

    class GdalUnavailableError    < StandardError; end
    class WarpError                < StandardError; end
    class InsufficientGcpsError    < StandardError; end

    MIN_GCPS_FOR_ORDER = { 1 => 3, 2 => 6, 3 => 10, "tps" => 3 }.freeze

    def initialize(source_path:, gcps:, order: 1)
      @source_path = source_path
      @gcps        = gcps   # array de hashes: [{px:, py:, wx:, wy:}, ...]
      @order       = order
    end

    def self.gdal_available?
      REQUIRED_BIN.all? { |b| system("which #{b} > /dev/null 2>&1") }
    end

    def self.choose_order(gcp_count)
      return 3   if gcp_count >= MIN_GCPS_FOR_ORDER[3]
      return 2   if gcp_count >= MIN_GCPS_FOR_ORDER[2]
      return 1   if gcp_count >= MIN_GCPS_FOR_ORDER[1]
      raise InsufficientGcpsError, "Sunt necesare minim 3 GCP-uri"
    end

    def call
      raise GdalUnavailableError, "GDAL nu este instalat (gdal_translate / gdalwarp / gdalinfo)" unless self.class.gdal_available?

      min = MIN_GCPS_FOR_ORDER[@order] || 3
      if @gcps.size < min
        raise InsufficientGcpsError, "Pentru ordinul #{@order} sunt necesare minim #{min} GCP-uri (au fost furnizate #{@gcps.size})"
      end

      Dir.mktmpdir("georef_warp_") do |dir|
        vrt_path     = File.join(dir, "with_gcps.vrt")
        warped_path  = File.join(dir, "warped.tif")

        translate_cmd = build_translate_cmd(vrt_path)
        run_or_raise(translate_cmd, "gdal_translate")

        warp_cmd = build_warp_cmd(vrt_path, warped_path)
        run_or_raise(warp_cmd, "gdalwarp")

        info = JSON.parse(`gdalinfo -json #{Shellwords.escape(warped_path)} 2>/dev/null`)
        bounds = extract_bounds_3844(info)
        width  = info.dig("size", 0) || info["rasterXSize"]
        height = info.dig("size", 1) || info["rasterYSize"]

        # Copiem rezultatul într-o locație stabilă (Dir.mktmpdir o șterge la ieșire).
        stable_path = Rails.root.join("tmp", "warped_#{SecureRandom.hex(8)}.tif").to_s
        FileUtils.cp(warped_path, stable_path)

        Result.new(
          warped_path: stable_path,
          bounds_3844: bounds,
          width:       width,
          height:      height,
          method:      @order == "tps" ? "tps" : "polynomial_order_#{@order}"
        )
      end
    end

    private

    def build_translate_cmd(vrt_path)
      gcp_args = @gcps.flat_map do |g|
        ["-gcp", g[:px].to_s, g[:py].to_s, g[:wx].to_s, g[:wy].to_s]
      end
      [
        "gdal_translate",
        *gcp_args,
        "-of", "VRT",
        @source_path,
        vrt_path
      ]
    end

    def build_warp_cmd(vrt_path, out_path)
      base = [
        "gdalwarp",
        "-t_srs", "EPSG:3844",
        "-r", "bilinear",
        "-overwrite",
        "-dstalpha"
      ]
      base += @order == "tps" ? ["-tps"] : ["-order", @order.to_s]
      base + [vrt_path, out_path]
    end

    def run_or_raise(cmd, label)
      out = `#{cmd.map { |a| Shellwords.escape(a) }.join(' ')} 2>&1`
      unless $?.success?
        raise WarpError, "#{label} eșuat: #{out.lines.last(3).join.strip}"
      end
    end

    def extract_bounds_3844(info)
      # gdalinfo -json -> "cornerCoordinates" pentru pixel corners în CRS-ul nativ.
      # După gdalwarp -t_srs EPSG:3844 toate colțurile sunt direct în 3844.
      c = info["cornerCoordinates"] || info["wgs84Extent"] # fallback
      if c && c["upperLeft"] && c["lowerRight"]
        x_min = [c["upperLeft"][0], c["lowerLeft"][0]].min
        x_max = [c["upperRight"][0], c["lowerRight"][0]].max
        y_min = [c["lowerLeft"][1], c["lowerRight"][1]].min
        y_max = [c["upperLeft"][1], c["upperRight"][1]].max
        [x_min, y_min, x_max, y_max]
      elsif info["geoTransform"] && info["size"]
        gt = info["geoTransform"]
        w, h = info["size"]
        # x = gt0 + col*gt1 + row*gt2; y = gt3 + col*gt4 + row*gt5
        corners = [[0, 0], [w, 0], [w, h], [0, h]].map do |(col, row)|
          [gt[0] + col * gt[1] + row * gt[2], gt[3] + col * gt[4] + row * gt[5]]
        end
        xs = corners.map(&:first); ys = corners.map(&:last)
        [xs.min, ys.min, xs.max, ys.max]
      else
        raise WarpError, "Nu pot extrage bounds din gdalinfo"
      end
    end
  end
end
