class GisGeorefPlan < ApplicationRecord
  # Plan vechi georeferențiat. Se încarcă un raster oarecare (JPG/PNG/PDF/TIFF),
  # utilizatorul plasează 3+ puncte de control (GCP) care leagă pixel ↔ coord
  # Stereo70, iar sistemul calculează transformarea afină.
  #
  # `owner_token` — identificator stabil per browser (cookie semnat), aceeași
  # convenție ca la `GisUserLayerPref`. La integrarea în e-CAD prod se va
  # înlocui cu `user_id`.
  has_one_attached :raster_file
  has_many :control_points,
           -> { order(:ordinal, :id) },
           class_name: "GisGeorefControlPoint",
           foreign_key: :gis_georef_plan_id,
           dependent: :destroy

  STATES = %w[draft georeferenced finalized].freeze

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
  def display_corners_world
    return nil if transform_params.blank? || original_width.blank? || original_height.blank?

    corners_px = [[0, 0], [original_width, 0], [original_width, original_height], [0, original_height]]
    corners_px.map { |(px, py)| Gis::AffineTransform.apply_forward(transform_params, px, py) }
  end

  def bounds_extent_3844
    return nil unless transform_params.present? && original_width.present? && original_height.present?

    corners = display_corners_world
    xs = corners.map(&:first)
    ys = corners.map(&:last)
    [xs.min, ys.min, xs.max, ys.max]
  end

  def raster_url
    return nil unless raster_file.attached?
    Rails.application.routes.url_helpers.rails_blob_path(raster_file, only_path: true)
  end
end
