# Tile grid for EPSG:3844 (Stereo70). Aligned with the OpenLayers `stereoGrid`
# defined in `harta_map_controller.js#_buildLayers` — origin NW corner, 15
# resolution levels, 256×256 px tiles. Identic grid pentru raster + vector
# tiles → tile (z, x, y) acoperă același bbox geografic în ambele cazuri.
#
# Conversion from tile coords (z, x, y) to bbox in EPSG:3844 meters:
#   tile_size_m = RESOLUTIONS[z] * TILE_SIZE_PX
#   min_x = ORIGIN_X + x * tile_size_m
#   max_y = ORIGIN_Y - y * tile_size_m
#   max_x = min_x + tile_size_m
#   min_y = max_y - tile_size_m
module TileGrid
  # Resolutions in meters/pixel, indexed by zoom level. Halved at each level
  # except the highest 2 (extra precision pentru editare la zoom max).
  RESOLUTIONS = [
    3072.0, 1536.0, 768.0, 384.0, 192.0,
    96.0,   48.0,   24.0,  12.0,  6.0,
    3.0,    1.5,    0.75,  0.375, 0.1875
  ].freeze

  # NW corner (Stereo70 metri). Acoperă tot teritoriul României cu o margine.
  ORIGIN_X = 120_000.0
  ORIGIN_Y = 800_000.0
  TILE_SIZE_PX = 256

  MAX_ZOOM = RESOLUTIONS.length - 1

  # Returns [min_x, min_y, max_x, max_y] în EPSG:3844 metri pentru tile (z, x, y).
  # Y crește spre sud (convenție XYZ standard, oglindit TMS).
  # Returnează nil dacă z, x sau y sunt în afara grilei.
  def self.bbox(z, x, y)
    return nil if z < 0 || z > MAX_ZOOM
    return nil if x < 0 || y < 0
    tile_size_m = RESOLUTIONS[z] * TILE_SIZE_PX
    min_x = ORIGIN_X + x * tile_size_m
    max_y = ORIGIN_Y - y * tile_size_m
    max_x = min_x + tile_size_m
    min_y = max_y - tile_size_m
    [min_x, min_y, max_x, max_y]
  end
end
