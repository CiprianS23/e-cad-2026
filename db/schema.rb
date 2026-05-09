# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_05_09_150302) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "postgis"

  create_table "parcele_cadastrale", force: :cascade do |t|
    t.string "adresa"
    t.string "categoria_folosinta", null: false
    t.geometry "centroid", limit: {:srid=>3844, :type=>"st_point"}
    t.string "cnp_cui_proprietar"
    t.datetime "created_at", null: false
    t.geometry "geom", limit: {:srid=>3844, :type=>"multi_polygon"}
    t.string "judet", null: false
    t.string "localitate", null: false
    t.string "numar_cadastral", null: false
    t.string "numar_topografic"
    t.string "proprietar"
    t.string "status", default: "activ", null: false
    t.decimal "suprafata_mp", precision: 12, scale: 4
    t.datetime "updated_at", null: false
    t.index ["centroid"], name: "index_parcele_cadastrale_on_centroid", using: :gist
    t.index ["geom"], name: "index_parcele_cadastrale_on_geom", using: :gist
    t.index ["judet"], name: "index_parcele_cadastrale_on_judet"
    t.index ["numar_cadastral"], name: "index_parcele_cadastrale_on_numar_cadastral", unique: true
    t.index ["status"], name: "index_parcele_cadastrale_on_status"
  end
end
