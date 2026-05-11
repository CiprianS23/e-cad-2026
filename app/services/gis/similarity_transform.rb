require "matrix"

# Transformare similitudine 2D (Helmert improper) pixel ↔ world.
# 4 parametri: translație (tx, ty), rotație (θ), scară uniformă (s).
#
# CONVENȚII DE AXE — critic:
#   - Spațiu pixel: (col, row) cu row crescând în JOS (convenția imaginii).
#   - Spațiu world: (X=east, Y=north) cu Y crescând în SUS (convenția GIS).
#   → modelul include reflexia Y (y-flip) ca să mapeze între cele două:
#
#     X = a*col + b*row + tx
#     Y = b*col - a*row + ty
#
#   unde a = s*cos(θ), b = s*sin(θ). Spre deosebire de similitudinea Y-up
#   pură (a, -b; b, a), aici al doilea rând al matricei e (b, -a) = reflexia
#   row-ului. Asta e exact ce face un scanner: imaginea citită „de sus în
#   jos", world-ul citit „de jos în sus". Fără y-flip, planul apare rotit
#   90° sau oglindit.
#
# Fit: 2n ecuații, 4 necunoscute (a, b, tx, ty). Least-squares.
module Gis
  class SimilarityTransform
    MIN_POINTS = 2

    Result = Struct.new(:params, :residuals, :residual_rms, keyword_init: true)

    def self.from_points(pixels, world)
      raise ArgumentError, "Need at least #{MIN_POINTS} points" if pixels.size < MIN_POINTS
      raise ArgumentError, "Mismatched arrays" if pixels.size != world.size

      # Ecuațiile (în ordinea [a, b, tx, ty]):
      #   X_i = a*col_i + b*row_i + tx   → [col_i,  row_i, 1, 0]
      #   Y_i = b*col_i − a*row_i + ty   → [−row_i, col_i, 0, 1]
      rows   = []
      target = []
      pixels.each_with_index do |(col, row), i|
        x_w, y_w = world[i]
        rows   << [col.to_f,  row.to_f, 1.0, 0.0]; target << x_w.to_f
        rows   << [-row.to_f, col.to_f, 0.0, 1.0]; target << y_w.to_f
      end
      a   = Matrix.rows(rows)
      at  = a.transpose
      ata = at * a
      ata_inv = ata.inverse
      params_vec = (ata_inv * at * Matrix.column_vector(target)).to_a.flatten
      a_p, b_p, tx, ty = params_vec

      params = {
        "scale"    => Math.sqrt(a_p**2 + b_p**2),
        "rotation" => Math.atan2(b_p, a_p),
        "tx"       => tx,
        "ty"       => ty,
        # Forma 6-param afină echivalentă (pentru compat cu apply_forward
        # din AffineTransform):
        #   x' = a*col + b*row + c → coef (a, b, c)
        #   y' = d*col + e*row + f → coef (d=b_p, e=-a_p, f=ty)
        "a" => a_p,  "b" => b_p,  "c" => tx,
        "d" => b_p,  "e" => -a_p, "f" => ty
      }

      residuals = pixels.each_with_index.map do |(col, row), i|
        pred_x = a_p * col + b_p * row + tx
        pred_y = b_p * col - a_p * row + ty
        Math.sqrt((pred_x - world[i][0])**2 + (pred_y - world[i][1])**2)
      end
      rms = Math.sqrt(residuals.sum { |r| r**2 } / residuals.size)

      Result.new(params: params, residuals: residuals, residual_rms: rms)
    end

    # GDAL GeoTransform pentru modelul nostru: [c, a, b, f, d, e]
    #   X = c + col*a + row*b
    #   Y = f + col*d + row*e
    # Corespunzător cu (a, b, c, d, e, f) din `from_points` care deja includ
    # y-flip-ul (e = -a_p, deci dY/drow e negativ pentru row descrescător
    # spre nord — exact ce vrea GDAL pentru north-up).
    def self.geotransform(params)
      [params["c"], params["a"], params["b"], params["f"], params["d"], params["e"]]
    end
  end
end
