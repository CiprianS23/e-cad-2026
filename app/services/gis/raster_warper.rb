require "shellwords"
require "tmpdir"
require "json"

# Warp un raster sursă (orice format suportat de GDAL) folosind o listă de
# puncte de control GCP în EPSG:3844. Produce un GeoTIFF georeferențiat în
# Stereo70, pregătit pentru afișare ca `ol.source.ImageStatic` peste harta
# principală sau pentru încărcare ulterioară în PostGIS raster.
#
# Suportă două familii de transformări:
#
# 1. **Similitudine (4 DOF)** — translate + rotate + scale UNIFORM. Modelul
#    corect pentru planuri cadastrale scanate care nu au distorsiuni interne.
#    Implementat manual: fit Helmert + VRT cu GeoTransform + gdalwarp pentru
#    re-grilare. `order: "similarity"` (default).
#
# 2. **Polinomial (GDAL nativ)** — order 1 = afină (6 DOF), order 2/3 corectează
#    distorsiuni curbate, tps = thin-plate spline (fit exact prin GCP-uri).
#    Folosit pentru planuri cu distorsiune internă (e.g. plan pe suport hârtie
#    deformat).
#
# Pentru sursele cu paletă indexată (color_interp=Palette, tipic pentru hărți
# scanate), expandăm la RGB ÎNAINTE de resample — altfel gdalwarp interpolează
# indecșii paletei și produce gunoi (preview iese negru).
module Gis
  class RasterWarper
    REQUIRED_BIN = %w[gdal_translate gdalwarp gdalinfo].freeze

    Result = Struct.new(:warped_path, :bounds_3844, :width, :height, :method, :residual_rms, keyword_init: true)

    class GdalUnavailableError < StandardError; end
    class WarpError            < StandardError; end
    class InsufficientGcpsError < StandardError; end

    # proj4 al EPSG:3844 — folosit direct ca să evităm confuzia de ordine a axelor.
    # EPSG:3844 OFICIAL e (axa1=X=north, axa2=Y=east), dar proj4 și restul
    # aplicației (OL, frontend, DB) folosesc convenția GIS tradițională
    # (X=east, Y=north). Cu STEREO70_PROJ4 forțăm GDAL să respecte aceeași convenție.
    STEREO70_PROJ4 = "+proj=sterea +lat_0=46 +lon_0=25 +k=0.99975 +x_0=500000 +y_0=500000 +ellps=krass +towgs84=33.4,-146.6,-76.3,-0.359,-0.053,0.844,-0.84 +units=m +no_defs".freeze

    # Pentru "similarity": minim 2 (4 ecuații, 4 necunoscute). Pentru gdalwarp
    # polynomial: minim 3 (affine).
    MIN_GCPS_FOR_ORDER = { "similarity" => 2, 1 => 3, 2 => 6, 3 => 10, "tps" => 3 }.freeze

    def initialize(source_path:, gcps:, order: "similarity")
      @source_path = source_path
      @gcps        = gcps
      @order       = order
    end

    def self.gdal_available?
      REQUIRED_BIN.all? { |b| system("which #{b} > /dev/null 2>&1") }
    end

    # Default: similitudine. Pentru ≥10 GCP-uri pe plan distorsionat user-ul
    # poate alege explicit polinomial. NU mai escaladăm automat la polinomial 2/3.
    def self.choose_order(_gcp_count)
      "similarity"
    end

    def call
      raise GdalUnavailableError, "GDAL nu este instalat" unless self.class.gdal_available?

      min = MIN_GCPS_FOR_ORDER[@order] || 3
      if @gcps.size < min
        raise InsufficientGcpsError, "Pentru metoda #{@order} sunt necesare minim #{min} GCP-uri (au fost furnizate #{@gcps.size})"
      end

      Dir.mktmpdir("georef_warp_") do |dir|
        # Pas 0: dacă sursa e palette (indexed color), expandăm la RGBA.
        # Altfel resample-ul ar interpola indecși de paletă = garbage (preview negru).
        prepared_source = prepare_source(@source_path, dir)

        warped_path = File.join(dir, "warped.tif")
        rms         = nil

        if @order == "similarity"
          # Pipeline custom pentru similitudine: fit Helmert, scriu VRT cu
          # GeoTransform explicit, las gdalwarp să re-grileze.
          rms = warp_similarity(prepared_source, dir, warped_path)
        else
          # Pipeline polinomial nativ GDAL
          vrt_path = File.join(dir, "with_gcps.vrt")
          run_or_raise(build_translate_cmd(prepared_source, vrt_path), "gdal_translate")
          run_or_raise(build_warp_cmd(vrt_path, warped_path), "gdalwarp")
        end

        info = JSON.parse(`gdalinfo -json #{Shellwords.escape(warped_path)} 2>/dev/null`)
        bounds = extract_bounds_3844(info)
        width  = info.dig("size", 0) || info["rasterXSize"]
        height = info.dig("size", 1) || info["rasterYSize"]

        stable_path = Rails.root.join("tmp", "warped_#{SecureRandom.hex(8)}.tif").to_s
        FileUtils.cp(warped_path, stable_path)

        # Construim piramide GDAL (overviews) pentru randare rapidă la zoom-out.
        # Fără overviews, browser-ul ar trebui să decodeze tot rasterul de
        # ~15k×22k px la fiecare redraw — extrem de lent.
        build_overviews(stable_path)

        Result.new(
          warped_path:  stable_path,
          bounds_3844:  bounds,
          width:        width,
          height:       height,
          method:       @order == "similarity" ? "similarity" : (@order == "tps" ? "tps" : "polynomial_order_#{@order}"),
          residual_rms: rms
        )
      end
    end

    private

    def prepare_source(source_path, dir)
      info = gdalinfo_json(source_path)
      is_palette = info.dig("bands", 0, "colorInterpretation") == "Palette"
      return source_path unless is_palette

      # Expandare palette → RGBA. Output tot TIFF, cu compresie LZW pentru a
      # nu exploda spațiul (paleta 1B/px → RGBA 4B/px este 4× mai mare).
      expanded = File.join(dir, "expanded_rgba.tif")
      run_or_raise(
        ["gdal_translate", "-expand", "rgba",
         "-co", "COMPRESS=LZW", "-co", "TILED=YES",
         source_path, expanded],
        "gdal_translate -expand rgba"
      )
      expanded
    end

    # Pipeline similitudine: fit Helmert, scriu VRT cu GeoTransform, gdalwarp
    # rerasterizează la grilă north-up în EPSG:3844.
    def warp_similarity(source_path, dir, out_path)
      pixels = @gcps.map { |g| [g[:px], g[:py]] }
      world  = @gcps.map { |g| [g[:wx], g[:wy]] }
      sim    = Gis::SimilarityTransform.from_points(pixels, world)

      info  = gdalinfo_json(source_path)
      width  = info["size"][0]
      height = info["size"][1]

      # Construim VRT minim cu source-ul actual + GeoTransform similitudine + SRS.
      # gdalwarp e configurat să citească VRT, să aplice geotransform-ul, și să
      # rerasterizeze la o grilă north-up.
      gt       = Gis::SimilarityTransform.geotransform(sim.params)
      vrt_path = File.join(dir, "similarity.vrt")
      File.write(vrt_path, build_similarity_vrt(source_path, info, gt))

      run_or_raise(
        ["gdalwarp", "-t_srs", STEREO70_PROJ4, "-r", "bilinear",
         "-overwrite", "-dstalpha",
         "-co", "COMPRESS=LZW", "-co", "TILED=YES", "-co", "BIGTIFF=IF_SAFER",
         vrt_path, out_path],
        "gdalwarp similarity"
      )

      sim.residual_rms
    end

    # VRT minim care referă sursa și aplică geotransform-ul similitudine.
    # Listează benzile sursei (RGBA pentru palette-expanded; orice pentru altele).
    def build_similarity_vrt(source_path, info, gt)
      bands  = info["bands"]
      width  = info["size"][0]
      height = info["size"][1]

      band_xml = bands.each_with_index.map do |b, i|
        idx  = i + 1
        type = b["type"] || "Byte"
        ci   = b["colorInterpretation"] || "Gray"
        <<~XML
          <VRTRasterBand dataType="#{type}" band="#{idx}">
            <ColorInterp>#{ci}</ColorInterp>
            <SimpleSource>
              <SourceFilename relativeToVRT="0">#{source_path}</SourceFilename>
              <SourceBand>#{idx}</SourceBand>
              <SrcRect xOff="0" yOff="0" xSize="#{width}" ySize="#{height}"/>
              <DstRect xOff="0" yOff="0" xSize="#{width}" ySize="#{height}"/>
            </SimpleSource>
          </VRTRasterBand>
        XML
      end.join

      <<~XML
        <VRTDataset rasterXSize="#{width}" rasterYSize="#{height}">
          <SRS>#{STEREO70_PROJ4}</SRS>
          <GeoTransform>#{gt.map { |v| format('%.10f', v) }.join(', ')}</GeoTransform>
          #{band_xml}
        </VRTDataset>
      XML
    end

    # Construiește piramide (overviews) pentru randare rapidă la zoom-out.
    # 5 niveluri (1/2, 1/4, 1/8, 1/16, 1/32). Resampling AVERAGE pentru imagini
    # naturale / scanări — păstrează tonalitatea mai bine decât NEAREST.
    def build_overviews(tiff_path)
      cmd = ["gdaladdo", "-r", "average", tiff_path, "2", "4", "8", "16", "32"]
      out = `#{cmd.map { |a| Shellwords.escape(a) }.join(' ')} 2>&1`
      Rails.logger.info "gdaladdo: #{out.lines.last.to_s.strip}" if $?.success?
      Rails.logger.warn "gdaladdo eșuat (continuăm fără): #{out.lines.last(2).join.strip}" unless $?.success?
    end

    def build_translate_cmd(source_path, vrt_path)
      gcp_args = @gcps.flat_map do |g|
        ["-gcp", g[:px].to_s, g[:py].to_s, g[:wx].to_s, g[:wy].to_s]
      end
      ["gdal_translate", *gcp_args, "-of", "VRT", source_path, vrt_path]
    end

    def build_warp_cmd(vrt_path, out_path)
      base = [
        "gdalwarp", "-t_srs", STEREO70_PROJ4, "-r", "bilinear",
        "-overwrite", "-dstalpha",
        "-co", "COMPRESS=LZW", "-co", "TILED=YES", "-co", "BIGTIFF=IF_SAFER"
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

    def gdalinfo_json(path)
      out = `gdalinfo -json #{Shellwords.escape(path)} 2>/dev/null`
      return nil unless $?.success?
      JSON.parse(out)
    end

    def extract_bounds_3844(info)
      c = info["cornerCoordinates"] || info["wgs84Extent"]
      if c && c["upperLeft"] && c["lowerRight"]
        x_min = [c["upperLeft"][0], c["lowerLeft"][0]].min
        x_max = [c["upperRight"][0], c["lowerRight"][0]].max
        y_min = [c["lowerLeft"][1], c["lowerRight"][1]].min
        y_max = [c["upperLeft"][1], c["upperRight"][1]].max
        [x_min, y_min, x_max, y_max]
      elsif info["geoTransform"] && info["size"]
        gt = info["geoTransform"]
        w, h = info["size"]
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
