require "matrix"

# Calculează transformarea afină 2D pixel ↔ world (EPSG:3844) din puncte
# de control (GCP). Folosește metoda celor mai mici pătrate pentru 4+ puncte;
# pentru exact 3 puncte returnează soluția exactă.
#
# Modelul afin:
#   x' = a*x + b*y + c
#   y' = d*x + e*y + f
#
# unde (x, y) = coordonate pixel și (x', y') = coordonate world (Stereo70).
module Gis
  class AffineTransform
    MIN_POINTS = 3

    Result = Struct.new(:params, :residuals, :residual_rms, keyword_init: true)

    def self.from_points(pixels, world)
      raise ArgumentError, "Need at least #{MIN_POINTS} points" if pixels.size < MIN_POINTS
      raise ArgumentError, "Mismatched arrays"                  if pixels.size != world.size

      # A (n×3): fiecare rând = [px, py, 1]
      a   = Matrix.rows(pixels.map { |(px, py)| [px.to_f, py.to_f, 1.0] })
      at  = a.transpose
      ata = at * a
      ata_inv = ata.inverse

      bx = Matrix.column_vector(world.map { |(wx, _)| wx.to_f })
      by = Matrix.column_vector(world.map { |(_, wy)| wy.to_f })

      px_params = (ata_inv * at * bx).to_a.flatten  # [a, b, c]
      py_params = (ata_inv * at * by).to_a.flatten  # [d, e, f]

      params = {
        "a" => px_params[0], "b" => px_params[1], "c" => px_params[2],
        "d" => py_params[0], "e" => py_params[1], "f" => py_params[2]
      }

      residuals = pixels.each_with_index.map do |(px, py), i|
        pred_x = params["a"] * px + params["b"] * py + params["c"]
        pred_y = params["d"] * px + params["e"] * py + params["f"]
        Math.sqrt((pred_x - world[i][0])**2 + (pred_y - world[i][1])**2)
      end
      rms = Math.sqrt(residuals.sum { |r| r**2 } / residuals.size)

      Result.new(params: params, residuals: residuals, residual_rms: rms)
    end

    # Aplică transformarea înainte (pixel → world).
    def self.apply_forward(params, px, py)
      [
        params["a"] * px + params["b"] * py + params["c"],
        params["d"] * px + params["e"] * py + params["f"]
      ]
    end

    # Bounding box în coordonate world al unei imagini cu dimensiunile date,
    # după aplicarea transformării pe cele 4 colțuri.
    # Returnează WKT EPSG:3844 al poligonului închis (clockwise).
    def self.bounds_polygon_wkt(params, width, height)
      corners_px = [[0, 0], [width, 0], [width, height], [0, height]]
      corners_w  = corners_px.map { |(px, py)| apply_forward(params, px, py) }
      ring       = corners_w + [corners_w.first]
      coords     = ring.map { |(x, y)| "#{x} #{y}" }.join(", ")
      "POLYGON((#{coords}))"
    end
  end
end
