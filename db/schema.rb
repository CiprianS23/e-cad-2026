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

ActiveRecord::Schema[8.1].define(version: 2026_05_09_160015) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "postgis"

  create_table "addresses", force: :cascade do |t|
    t.string "apno", limit: 50
    t.string "block", limit: 50
    t.datetime "created_at", null: false
    t.text "description"
    t.string "districtname", limit: 50
    t.string "districttype", limit: 50
    t.string "entry", limit: 50
    t.string "floor", limit: 50
    t.boolean "intravilan", default: false
    t.string "postalnumber", limit: 50
    t.string "section", limit: 100
    t.string "sirsup", limit: 50
    t.string "siruta", limit: 50
    t.string "streetname", limit: 50
    t.string "streettype", limit: 50
    t.datetime "updated_at", null: false
    t.string "zipcode", limit: 50
  end

  create_table "building_common_parts", force: :cascade do |t|
    t.bigint "building_id"
    t.string "commonparttype", limit: 255
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["building_id"], name: "index_building_common_parts_on_building_id"
  end

  create_table "buildings", force: :cascade do |t|
    t.bigint "address_id"
    t.string "buildingdestination", limit: 50
    t.integer "buildno", null: false
    t.string "cadgenno", limit: 200
    t.datetime "created_at", null: false
    t.string "e2identifier", limit: 200
    t.boolean "islegal", default: true, null: false
    t.integer "iuno", default: 0
    t.bigint "land_id", null: false
    t.float "legalarea"
    t.integer "levelsno"
    t.float "measuredarea", default: 0.0
    t.text "notes"
    t.string "papercadno", limit: 200
    t.string "paperlbno", limit: 200
    t.float "taxvalue"
    t.string "topono", limit: 200
    t.float "totalarea", default: 0.0
    t.datetime "updated_at", null: false
    t.index ["address_id"], name: "index_buildings_on_address_id"
    t.index ["land_id"], name: "index_buildings_on_land_id"
  end

  create_table "contested_x_entities", force: :cascade do |t|
    t.bigint "building_id"
    t.bigint "contested_id"
    t.datetime "created_at", null: false
    t.bigint "individual_unit_id"
    t.bigint "land_id"
    t.datetime "updated_at", null: false
    t.index ["building_id"], name: "index_contested_x_entities_on_building_id"
    t.index ["contested_id"], name: "index_contested_x_entities_on_contested_id"
    t.index ["individual_unit_id"], name: "index_contested_x_entities_on_individual_unit_id"
    t.index ["land_id"], name: "index_contested_x_entities_on_land_id"
  end

  create_table "contesteds", force: :cascade do |t|
    t.datetime "contesteddate"
    t.integer "contestednumber"
    t.datetime "created_at", null: false
    t.datetime "solutiondate"
    t.integer "solutionnumber"
    t.datetime "updated_at", null: false
  end

  create_table "deeds", force: :cascade do |t|
    t.string "authority", limit: 50, null: false
    t.datetime "created_at", null: false
    t.datetime "deeddate"
    t.string "deednumber", limit: 200, null: false
    t.string "deedtype", limit: 255, null: false
    t.bigint "file_description_id", null: false
    t.text "notes"
    t.datetime "updated_at", null: false
    t.string "valueamount", limit: 200
    t.string "valuecurrency", limit: 50
    t.index ["file_description_id"], name: "index_deeds_on_file_description_id"
  end

  create_table "file_descriptions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "exportdate"
    t.string "filename", limit: 50, null: false
    t.string "fileversion", limit: 50
    t.string "licensedname", limit: 255
    t.string "licensenumber", limit: 50
    t.string "operationtype", limit: 50
    t.datetime "updated_at", null: false
  end

  create_table "individual_units", force: :cascade do |t|
    t.string "apno", limit: 50
    t.bigint "building_id"
    t.string "cadgenno", limit: 200
    t.string "commonpartsarea"
    t.string "commonpartstype"
    t.datetime "created_at", null: false
    t.string "e2identifier", limit: 200
    t.string "entry", limit: 50
    t.string "floor", limit: 50
    t.string "identifier", limit: 50, null: false
    t.string "landdivisiontype"
    t.string "landindivisionarea"
    t.float "measuredarea"
    t.text "notes"
    t.string "papercadno", limit: 200
    t.string "paperlbno", limit: 200
    t.integer "roomno"
    t.string "section", limit: 50
    t.string "topono", limit: 200
    t.float "totalarea"
    t.datetime "updated_at", null: false
    t.index ["building_id"], name: "index_individual_units_on_building_id"
  end

  create_table "lands", force: :cascade do |t|
    t.bigint "address_id"
    t.float "buildinglegalarea"
    t.string "cadgenno", limit: 200
    t.string "cadsector", limit: 200
    t.boolean "coarea"
    t.datetime "created_at", null: false
    t.string "e2identifier", limit: 200
    t.boolean "enclosed"
    t.bigint "file_description_id"
    t.boolean "isnew", default: true
    t.float "measuredarea", default: 0.0, null: false
    t.text "notes"
    t.string "papercadno", limit: 200
    t.string "paperlbno", limit: 200
    t.float "parcellegalarea"
    t.float "taxvalue"
    t.string "topono", limit: 200
    t.datetime "updated_at", null: false
    t.index ["address_id"], name: "index_lands_on_address_id"
    t.index ["file_description_id"], name: "index_lands_on_file_description_id"
  end

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

  create_table "parcels", force: :cascade do |t|
    t.string "cadgenno", limit: 200
    t.datetime "created_at", null: false
    t.string "e2identifier", limit: 200
    t.boolean "intravilan"
    t.bigint "land_id"
    t.string "landplotno", limit: 50
    t.float "measuredarea"
    t.text "notes"
    t.integer "number"
    t.string "papercadno", limit: 200
    t.string "paperlbno", limit: 200
    t.string "parcelno", limit: 50
    t.float "taxvalue"
    t.string "titleno", limit: 50
    t.string "topono", limit: 200
    t.datetime "updated_at", null: false
    t.string "usecategory", limit: 50
    t.index ["land_id"], name: "index_parcels_on_land_id"
  end

  create_table "persons", force: :cascade do |t|
    t.bigint "address_id"
    t.string "citizenshipcountry", limit: 50
    t.datetime "created_at", null: false
    t.boolean "defunct"
    t.string "email"
    t.string "fatherinitial", limit: 50
    t.bigint "file_description_id"
    t.string "firstname", limit: 255, null: false
    t.string "idcardnumber"
    t.string "idcardserialno", limit: 50
    t.string "idcardtype", limit: 50
    t.string "idcode", limit: 50
    t.boolean "identified"
    t.boolean "isphysical", default: true
    t.string "lastname", limit: 255
    t.text "notes"
    t.string "phone"
    t.string "previouslastname", limit: 50
    t.bigint "registration_id"
    t.datetime "updated_at", null: false
    t.index ["address_id"], name: "index_persons_on_address_id"
    t.index ["file_description_id"], name: "index_persons_on_file_description_id"
    t.index ["registration_id"], name: "index_persons_on_registration_id"
  end

  create_table "points", force: :cascade do |t|
    t.bigint "building_id"
    t.geometry "coordinates", limit: {:srid=>3844, :type=>"st_point"}
    t.datetime "created_at", null: false
    t.bigint "land_id"
    t.string "no", limit: 50
    t.datetime "updated_at", null: false
    t.float "x"
    t.float "y"
    t.index ["building_id"], name: "index_points_on_building_id"
    t.index ["coordinates"], name: "index_points_on_coordinates", using: :gist
    t.index ["land_id"], name: "index_points_on_land_id"
  end

  create_table "registration_x_entities", force: :cascade do |t|
    t.bigint "building_id"
    t.datetime "created_at", null: false
    t.bigint "individual_unit_id"
    t.bigint "land_id"
    t.bigint "registration_id"
    t.datetime "updated_at", null: false
    t.index ["building_id"], name: "index_registration_x_entities_on_building_id"
    t.index ["individual_unit_id"], name: "index_registration_x_entities_on_individual_unit_id"
    t.index ["land_id"], name: "index_registration_x_entities_on_land_id"
    t.index ["registration_id", "building_id"], name: "idx_reg_x_ent_reg_bld"
    t.index ["registration_id", "individual_unit_id"], name: "idx_reg_x_ent_reg_iu"
    t.index ["registration_id", "land_id"], name: "idx_reg_x_ent_reg_land"
    t.index ["registration_id"], name: "index_registration_x_entities_on_registration_id"
  end

  create_table "registrations", force: :cascade do |t|
    t.string "actualquota", limit: 50
    t.datetime "appdate"
    t.integer "appno"
    t.text "comments"
    t.datetime "created_at", null: false
    t.bigint "deed_id", null: false
    t.string "initialquota", limit: 50
    t.integer "lbpartno"
    t.text "notes"
    t.integer "position"
    t.string "quotatype", limit: 50
    t.string "registrationtype", null: false
    t.text "rightcomment"
    t.string "righttype", limit: 50
    t.string "title", limit: 50
    t.datetime "updated_at", null: false
    t.string "valueamount", limit: 50
    t.string "valuecurrency", limit: 50
    t.index ["deed_id"], name: "index_registrations_on_deed_id"
  end

  add_foreign_key "building_common_parts", "buildings"
  add_foreign_key "buildings", "addresses"
  add_foreign_key "buildings", "lands"
  add_foreign_key "contested_x_entities", "buildings"
  add_foreign_key "contested_x_entities", "contesteds"
  add_foreign_key "contested_x_entities", "individual_units"
  add_foreign_key "contested_x_entities", "lands"
  add_foreign_key "deeds", "file_descriptions"
  add_foreign_key "individual_units", "buildings"
  add_foreign_key "lands", "addresses"
  add_foreign_key "lands", "file_descriptions"
  add_foreign_key "parcels", "lands"
  add_foreign_key "persons", "addresses"
  add_foreign_key "persons", "file_descriptions"
  add_foreign_key "persons", "registrations"
  add_foreign_key "points", "buildings"
  add_foreign_key "points", "lands"
  add_foreign_key "registration_x_entities", "buildings"
  add_foreign_key "registration_x_entities", "individual_units"
  add_foreign_key "registration_x_entities", "lands"
  add_foreign_key "registration_x_entities", "registrations"
  add_foreign_key "registrations", "deeds"
end
