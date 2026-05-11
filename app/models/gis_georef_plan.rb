class GisGeorefPlan < ApplicationRecord
  # Plan vechi georeferențiat. Se încarcă un raster oarecare (JPG/PNG/PDF/TIFF),
  # utilizatorul plasează 3+ puncte de control (GCP) care leagă pixel ↔ coord
  # Stereo70, iar sistemul calculează transformarea afină.
  #
  # `owner_token` — identificator stabil per browser (cookie semnat), aceeași
  # convenție ca la `GisUserLayerPref`. La integrarea în e-CAD prod se va
  # înlocui cu `user_id`.
  has_one_attached :raster_file           # imaginea originală încărcată de utilizator
  has_one_attached :raster_preview_file   # PNG generat la upload — pentru afișare în browser (TIFF nu e suportat nativ)
  has_one_attached :warped_file           # GeoTIFF georeferențiat în EPSG:3844 (rezultat gdalwarp)
  has_one_attached :warped_preview_file   # JPEG/PNG downsampled al warped-ului — pentru afișare pe harta principală (browserele nu suportă TIFF)
  has_many :control_points,
           -> { order(:ordinal, :id) },
           class_name: "GisGeorefControlPoint",
           foreign_key: :gis_georef_plan_id,
           dependent: :destroy

  STATES = %w[draft georeferenced finalized].freeze
  WARP_METHODS = %w[auto similarity affine polynomial2 polynomial3 tps].freeze

  validates :name,        presence: true, length: { maximum: 200 }
  validates :owner_token, presence: true
  validates :state,       inclusion: { in: STATES }

  scope :for_owner,  ->(token) { where(owner_token: token) }
  scope :usable,     -> { where(state: %w[georeferenced finalized]) }

  # Recalculează transformarea afină din GCP-urile actuale și o persistă.
  # Returnează un hash { ok:, rms:, error: } pentru API.
  def recompute_georeference!
    cps = control_points.to_a
    if cps.size < Gis::AffineTransform::MIN_POINTS
      return { ok: false, error: "Sunt necesare minim #{Gis::AffineTransform::MIN_POINTS} puncte de control" }
    end

    pixels = cps.map { |c| [c.pixel_x, c.pixel_y] }
    world  = cps.map { |c| [c.world_x, c.world_y] }
    result = Gis::AffineTransform.from_points(pixels, world)

    ActiveRecord::Base.transaction do
      update!(
        transform_type:   "affine",
        transform_params: result.params,
        residual_rms:     result.residual_rms,
        state:            "georeferenced"
      )
      cps.each_with_index do |cp, i|
        cp.update!(residual: result.residuals[i])
      end
      assign_bounds_geom!(result.params)
    end

    { ok: true, rms: result.residual_rms }
  rescue ArgumentError => e
    { ok: false, error: e.message }
  rescue Matrix::ErrNotRegular
    { ok: false, error: "Punctele de control sunt coliniare — nu pot calcula transformarea" }
  end

  def assign_bounds_geom!(params = transform_params)
    return if original_width.blank? || original_height.blank? || params.blank?

    wkt = Gis::AffineTransform.bounds_polygon_wkt(params, original_width, original_height)
    self.class.connection.execute(
      ActiveRecord::Base.sanitize_sql_array([
        "UPDATE gis_georef_plans SET bounds_geom = ST_GeomFromText(?, 3844) WHERE id = ?",
        wkt, id
      ])
    )
    reload
  end

  # Pentru afișarea client-side: URL semnat către imaginea sursă (pentru a fi
  # randată via ol.source.ImageStatic) + colțurile world corespunzătoare.
  # Funcționează doar când avem parametri afini (state=georeferenced); pentru
  # finalized, geometria reală e dată de bounds_extent_3844.
  def display_corners_world
    return nil unless affine_params_present?
    return nil if original_width.blank? || original_height.blank?

    corners_px = [[0, 0], [original_width, 0], [original_width, original_height], [0, original_height]]
    corners_px.map { |(px, py)| Gis::AffineTransform.apply_forward(transform_params, px, py) }
  end

  # Bounding box pentru afișare pe hartă. Prioritate:
  #   1. `warp_bounds_3844` stocat în transform_params după finalize (bbox real
  #      al GeoTIFF-ului warped — fără distorsiuni).
  #   2. Calcul din colțurile transformate prin afină (când state=georeferenced).
  def bounds_extent_3844
    if transform_params.is_a?(Hash) && (b = transform_params["warp_bounds_3844"])
      return b
    end
    corners = display_corners_world
    return nil if corners.blank?
    xs = corners.map(&:first); ys = corners.map(&:last)
    [xs.min, ys.min, xs.max, ys.max]
  end

  private

  # Verifică dacă transform_params conține parametri afini (6 coeficienți).
  # După finalize păstrăm doar `warp_bounds_3844` și `warp_method`.
  def affine_params_present?
    return false unless transform_params.is_a?(Hash)
    %w[a b c d e f].all? { |k| transform_params.key?(k) }
  end

  public

  def raster_url
    return nil unless raster_file.attached?
    Rails.application.routes.url_helpers.rails_blob_path(raster_file, only_path: true)
  end

  # URL al variantei PNG pentru afișare în browser (TIFF/PDF nu sunt suportate
  # nativ). Fallback la raster_url când e deja PNG/JPG.
  def raster_preview_url
    if raster_preview_file.attached?
      Rails.application.routes.url_helpers.rails_blob_path(raster_preview_file, only_path: true)
    else
      raster_url
    end
  end

  def warped_url
    return nil unless warped_file.attached?
    Rails.application.routes.url_helpers.rails_blob_path(warped_file, only_path: true)
  end

  def warped_preview_url
    return nil unless warped_preview_file.attached?
    Rails.application.routes.url_helpers.rails_blob_path(warped_preview_file, only_path: true)
  end

  # Map URL preferat pentru afișarea pe harta principală. Ordinea:
  # 1. `warped_preview_file` — JPEG/PNG downsampled, browser-friendly
  # 2. `warped_file` — GeoTIFF (browser-ele moderne nu îl pot decodifica direct,
  #    dar îl lăsăm ca fallback dacă preview-ul nu s-a generat)
  # 3. `raster_file` — original (când warp n-a rulat încă)
  def display_url
    warped_preview_url || warped_url || raster_url
  end

  # Rulează (la upload) un pipeline GDAL pentru a:
  #   1. Citi dimensiunile reale ale imaginii sursă (original_width/height)
  #   2. Genera o variantă PNG pentru afișare în browser (raster_preview_file)
  # Se apelează din controller după `raster_file.attach`.
  def prepare_for_display!
    return unless raster_file.attached?
    raster_file.blob.open do |tempfile|
      src = tempfile.path

      # 1. Dimensiuni
      dims = Gis::RasterPreviewer.dimensions(src)
      if dims
        self.original_width  = dims[0]
        self.original_height = dims[1]
      end

      # 2. Preview pentru afișare browser (JPEG sau PNG fallback).
      # Generăm preview dacă: sursa nu e format browser, SAU e prea mare,
      # SAU avem deja un preview vechi care trebuie regenerat.
      long_side = dims ? [dims[0], dims[1]].max : 0
      src_ext   = File.extname(raster_file.filename.to_s).downcase
      needs_preview = long_side > Gis::RasterPreviewer::DEFAULT_MAX_DIM ||
                      !Gis::RasterPreviewer::BROWSER_FORMATS.include?(src_ext) ||
                      raster_preview_file.attached?  # regenerăm dacă există versiune veche

      if needs_preview
        # Detașăm versiunea veche înainte să atașăm una nouă (evităm blob-uri orfane)
        raster_preview_file.purge if raster_preview_file.attached?

        preview_path = Gis::RasterPreviewer.to_web_preview(src)
        preview_ext  = File.extname(preview_path).downcase
        content_type = preview_ext == ".png" ? "image/png" : "image/jpeg"
        Rails.logger.info "Plan ##{id}: preview generat la #{preview_path} (#{File.size(preview_path)} bytes, #{content_type})"

        raster_preview_file.attach(
          io:           File.open(preview_path, "rb"),
          filename:     "#{name.parameterize}_preview#{preview_ext}",
          content_type: content_type
        )
        File.delete(preview_path) if File.exist?(preview_path) && preview_path != src
      end

      save! if changed?
    end
  rescue Gis::RasterPreviewer::PreviewError => e
    Rails.logger.error "Plan ##{id}: PREVIEW EȘUAT — #{e.message}. Sursa: #{raster_file.filename}"
    # Re-raise pentru ca eroarea să fie vizibilă în controller-ul de upload.
    # Controller-ul setează flash.alert pentru ca user-ul să nu rămână fără
    # diagnostic (ar fi văzut ecran negru fără explicație).
    raise
  end

  # Rulează pipeline-ul gdalwarp pentru a produce un GeoTIFF georeferențiat
  # în EPSG:3844 din imaginea sursă și GCP-urile actuale. Stochează rezultatul
  # ca `warped_file` și actualizează bounds_geom, state, transform_type.
  #
  # `method`: "auto" (alege ordinul după nr GCP-uri) | "affine" | "polynomial2"
  #           | "polynomial3" | "tps"
  def finalize_warp!(method: "auto")
    raise "Nu există imagine sursă" unless raster_file.attached?
    cps = control_points.to_a
    raise "Sunt necesare minim 3 GCP-uri" if cps.size < 3

    order = case method
            when "auto"         then Gis::RasterWarper.choose_order(cps.size)
            when "similarity"   then "similarity"
            when "affine"       then 1
            when "polynomial2"  then 2
            when "polynomial3"  then 3
            when "tps"          then "tps"
            else raise "Metodă necunoscută: #{method}"
            end

    # Salvăm temporar imaginea sursă (Active Storage o ține în storage local
    # sau remote — gdal_translate are nevoie de un path).
    source_path = nil
    raster_file.blob.open do |tempfile|
      source_path = tempfile.path

      gcps_args = cps.map { |c| { px: c.pixel_x, py: c.pixel_y, wx: c.world_x, wy: c.world_y } }
      result = Gis::RasterWarper.new(source_path: source_path, gcps: gcps_args, order: order).call

      # Generăm preview JPEG/PNG al warped-ului ÎNAINTE de tranzacție (operațiune
      # I/O lentă pe fișier mare; o ținem afară din lock-ul de DB). Preview-ul
      # are aceleași bounds geografice, doar pixel-data e downsampled la <6000px
      # pe latura lungă. Crossbrowser-rendering vs TIFF.
      preview_path = nil
      begin
        # preserve_alpha: true → PNG (margins transparente vs negru sub JPEG).
        # max_dim 4000 e suficient pentru afișare pe harta principală — la
        # zoom mare utilizatorul poate vedea în continuare detaliile în pagina
        # /gis/georef_plans/X/edit care folosește preview-ul sursei.
        preview_path = Gis::RasterPreviewer.to_web_preview(result.warped_path, preserve_alpha: true, max_dim: 4000)
      rescue Gis::RasterPreviewer::PreviewError => e
        Rails.logger.warn "Plan ##{id}: preview warped eșuat — #{e.message}. Browserul va încerca să afișeze TIFF direct."
      end

      ActiveRecord::Base.transaction do
        # Atașează GeoTIFF-ul rezultat
        warped_file.attach(
          io:           File.open(result.warped_path, "rb"),
          filename:     "#{name.parameterize}_warped.tif",
          content_type: "image/tiff"
        )

        # Atașează preview-ul (când există)
        if preview_path
          preview_ext  = File.extname(preview_path).downcase
          content_type = preview_ext == ".png" ? "image/png" : "image/jpeg"
          warped_preview_file.purge if warped_preview_file.attached?
          warped_preview_file.attach(
            io:           File.open(preview_path, "rb"),
            filename:     "#{name.parameterize}_warped_preview#{preview_ext}",
            content_type: content_type
          )
        end

        # Bounds-ul real (după warp) — poligon închis în 3844
        ext = result.bounds_3844
        wkt = "POLYGON((#{ext[0]} #{ext[1]}, #{ext[2]} #{ext[1]}, #{ext[2]} #{ext[3]}, #{ext[0]} #{ext[3]}, #{ext[0]} #{ext[1]}))"
        self.class.connection.execute(
          ActiveRecord::Base.sanitize_sql_array([
            "UPDATE gis_georef_plans SET bounds_geom = ST_GeomFromText(?, 3844) WHERE id = ?",
            wkt, id
          ])
        )

        # Păstrăm parametrii afini calculați anterior (pentru reverse engineering
        # eventual) și adăugăm rezultatul warp în același jsonb.
        merged_params = (transform_params || {}).merge(
          "warp_bounds_3844" => ext,
          "warp_method"      => result.method,
          "warp_width"       => result.width,
          "warp_height"      => result.height
        )

        update!(
          transform_type:   result.method,
          transform_params: merged_params,
          state:            "finalized"
        )
        File.delete(result.warped_path) if File.exist?(result.warped_path)
        File.delete(preview_path) if preview_path && File.exist?(preview_path)
      end

      { ok: true, method: result.method, bounds: result.bounds_3844, width: result.width, height: result.height }
    end
  rescue Gis::RasterWarper::InsufficientGcpsError, Gis::RasterWarper::GdalUnavailableError, Gis::RasterWarper::WarpError => e
    { ok: false, error: e.message }
  end
end
