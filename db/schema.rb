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

ActiveRecord::Schema[8.1].define(version: 2026_05_11_180002) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "postgis"
  enable_extension "unaccent"

  create_table "addresses", force: :cascade do |t|
    t.string "apno"
    t.string "block"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "districtname"
    t.string "districttype"
    t.string "entry"
    t.string "floor"
    t.boolean "intravilan", default: false
    t.string "postalnumber"
    t.string "section"
    t.string "sirsup"
    t.string "siruta"
    t.string "streetname"
    t.string "streettype"
    t.datetime "updated_at", null: false
    t.string "zipcode"
  end

  create_table "building_common_parts", force: :cascade do |t|
    t.bigint "building_id"
    t.string "commonparttype"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["building_id"], name: "index_building_common_parts_on_building_id"
  end

  create_table "buildings", force: :cascade do |t|
    t.bigint "address_id"
    t.string "buildingdestination"
    t.integer "buildno", null: false
    t.string "cadgenno"
    t.datetime "created_at", null: false
    t.string "e2identifier"
    t.boolean "islegal", default: true, null: false
    t.integer "iuno", default: 0
    t.bigint "land_id", null: false
    t.float "legalarea"
    t.integer "levelsno"
    t.float "measuredarea", default: 0.0
    t.text "notes"
    t.string "papercadno"
    t.string "paperlbno"
    t.float "taxvalue"
    t.string "topono"
    t.float "totalarea", default: 0.0
    t.datetime "updated_at", null: false
    t.index ["address_id"], name: "index_buildings_on_address_id"
    t.index ["land_id"], name: "index_buildings_on_land_id"
  end

  create_table "cgxml_validation_errors", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "current_value"
    t.bigint "entity_id"
    t.string "entity_type", null: false
    t.string "error_code", null: false
    t.text "error_message", null: false
    t.string "expected_format"
    t.string "field_name"
    t.bigint "file_description_id", null: false
    t.datetime "fixed_at"
    t.string "fixed_by"
    t.string "severity", default: "error", null: false
    t.datetime "updated_at", null: false
    t.string "xpath"
    t.index ["entity_type", "entity_id"], name: "index_cgxml_validation_errors_on_entity_type_and_entity_id"
    t.index ["file_description_id", "entity_type"], name: "idx_on_file_description_id_entity_type_7a09c0a15d"
    t.index ["file_description_id", "error_code"], name: "idx_on_file_description_id_error_code_33f50cadc9"
    t.index ["file_description_id"], name: "index_cgxml_validation_errors_on_file_description_id"
    t.index ["fixed_at"], name: "index_cgxml_validation_errors_on_fixed_at"
  end

  create_table "cladiri_cadastrale", force: :cascade do |t|
    t.geometry "centroid", limit: {:srid=>3844, :type=>"st_point"}
    t.datetime "created_at", null: false
    t.string "destinatie"
    t.geometry "geom", limit: {:srid=>3844, :type=>"multi_polygon"}
    t.string "judet", null: false
    t.string "localitate", null: false
    t.string "numar_cadastral", null: false
    t.bigint "parcela_cadastrala_id", null: false
    t.string "proprietar"
    t.string "regim_inaltime"
    t.string "status", default: "activ", null: false
    t.decimal "suprafata_construita_mp", precision: 12, scale: 4
    t.datetime "updated_at", null: false
    t.index ["centroid"], name: "index_cladiri_cadastrale_on_centroid", using: :gist
    t.index ["geom"], name: "index_cladiri_cadastrale_on_geom", using: :gist
    t.index ["judet"], name: "index_cladiri_cadastrale_on_judet"
    t.index ["numar_cadastral"], name: "index_cladiri_cadastrale_on_numar_cadastral", unique: true
    t.index ["parcela_cadastrala_id"], name: "index_cladiri_cadastrale_on_parcela_cadastrala_id"
    t.index ["status"], name: "index_cladiri_cadastrale_on_status"
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
    t.string "authority", null: false
    t.datetime "created_at", null: false
    t.datetime "deeddate"
    t.string "deednumber", null: false
    t.string "deedtype", null: false
    t.bigint "file_description_id", null: false
    t.text "notes"
    t.datetime "updated_at", null: false
    t.string "valueamount"
    t.string "valuecurrency"
    t.index ["file_description_id"], name: "index_deeds_on_file_description_id"
  end

  create_table "file_descriptions", force: :cascade do |t|
    t.string "content_hash", limit: 64
    t.datetime "created_at", null: false
    t.datetime "exportdate"
    t.string "filename", null: false
    t.string "fileversion"
    t.integer "import_errors_count", default: 0, null: false
    t.string "import_status", default: "done", null: false
    t.datetime "imported_at"
    t.string "licensedname"
    t.string "licensenumber"
    t.string "operationtype"
    t.text "raw_xml"
    t.datetime "updated_at", null: false
    t.integer "validation_errors_count", default: 0, null: false
    t.string "validation_status", default: "pending", null: false
    t.integer "validation_warnings_count", default: 0, null: false
    t.index ["content_hash"], name: "index_file_descriptions_on_content_hash", unique: true
    t.index ["validation_status"], name: "index_file_descriptions_on_validation_status"
  end

  create_table "gis_user_layer_prefs", force: :cascade do |t|
    t.boolean "color_by_category"
    t.datetime "created_at", null: false
    t.string "fill_color"
    t.string "layer_key", null: false
    t.boolean "locked"
    t.float "max_resolution"
    t.float "min_resolution"
    t.float "opacity"
    t.string "owner_token", null: false
    t.string "stroke_color"
    t.string "stroke_dash"
    t.float "stroke_width"
    t.datetime "updated_at", null: false
    t.boolean "visible"
    t.integer "z_index"
    t.index ["owner_token", "layer_key"], name: "ix_gis_user_layer_prefs_owner_key", unique: true
    t.index ["owner_token"], name: "index_gis_user_layer_prefs_on_owner_token"
  end

  create_table "individual_units", force: :cascade do |t|
    t.string "apno"
    t.bigint "building_id"
    t.string "cadgenno"
    t.string "commonpartsarea"
    t.string "commonpartstype"
    t.datetime "created_at", null: false
    t.string "e2identifier"
    t.string "entry"
    t.string "floor"
    t.string "identifier", null: false
    t.string "landdivisiontype"
    t.string "landindivisionarea"
    t.float "measuredarea"
    t.text "notes"
    t.string "papercadno"
    t.string "paperlbno"
    t.integer "roomno"
    t.string "section"
    t.string "topono"
    t.float "totalarea"
    t.datetime "updated_at", null: false
    t.index ["building_id"], name: "index_individual_units_on_building_id"
  end

  create_table "lands", force: :cascade do |t|
    t.bigint "address_id"
    t.float "buildinglegalarea"
    t.string "cadgenno"
    t.string "cadsector"
    t.boolean "coarea"
    t.datetime "created_at", null: false
    t.string "e2identifier"
    t.boolean "enclosed"
    t.bigint "file_description_id"
    t.boolean "isnew", default: true
    t.float "measuredarea", default: 0.0, null: false
    t.text "notes"
    t.string "papercadno"
    t.string "paperlbno"
    t.float "parcellegalarea"
    t.float "taxvalue"
    t.string "topono"
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
    t.string "cadgenno"
    t.datetime "created_at", null: false
    t.string "e2identifier"
    t.boolean "intravilan"
    t.bigint "land_id"
    t.string "landplotno"
    t.float "measuredarea"
    t.text "notes"
    t.integer "number"
    t.string "papercadno"
    t.string "paperlbno"
    t.string "parcelno"
    t.float "taxvalue"
    t.string "titleno"
    t.string "topono"
    t.datetime "updated_at", null: false
    t.string "usecategory"
    t.index ["land_id"], name: "index_parcels_on_land_id"
  end

  create_table "persons", force: :cascade do |t|
    t.bigint "address_id"
    t.string "citizenshipcountry"
    t.datetime "created_at", null: false
    t.boolean "defunct"
    t.string "email"
    t.string "fatherinitial"
    t.bigint "file_description_id"
    t.string "firstname", null: false
    t.string "idcardnumber"
    t.string "idcardserialno"
    t.string "idcardtype"
    t.string "idcode"
    t.boolean "identified"
    t.boolean "isphysical", default: true
    t.string "lastname"
    t.text "notes"
    t.string "phone"
    t.string "previouslastname"
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
    t.string "no"
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
    t.string "actualquota"
    t.datetime "appdate"
    t.integer "appno"
    t.text "comments"
    t.datetime "created_at", null: false
    t.bigint "deed_id", null: false
    t.string "initialquota"
    t.integer "lbpartno"
    t.text "notes"
    t.integer "position"
    t.string "quotatype"
    t.string "registrationtype", null: false
    t.text "rightcomment"
    t.string "righttype"
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "valueamount"
    t.string "valuecurrency"
    t.index ["deed_id"], name: "index_registrations_on_deed_id"
  end

  create_table "siruta_uats", force: :cascade do |t|
    t.integer "cod_judet", null: false
    t.integer "cod_siruta", null: false
    t.string "denumire_judet", limit: 60, null: false
    t.string "denumire_uat", limit: 100, null: false
    t.integer "tip_uat", null: false
    t.string "tip_uat_abrev", limit: 4, null: false
    t.index ["cod_judet"], name: "index_siruta_uats_on_cod_judet"
    t.index ["cod_siruta"], name: "index_siruta_uats_on_cod_siruta", unique: true
    t.index ["denumire_uat"], name: "index_siruta_uats_on_denumire_uat"
  end

  create_table "uat_boundaries", force: :cascade do |t|
    t.date "begin_vers"
    t.date "end_version"
    t.geometry "geom", limit: {:srid=>3844, :type=>"multi_polygon"}
    t.string "local_id", limit: 254
    t.string "name", limit: 254
    t.string "nat_code", limit: 254
    t.string "nat_lev_name", limit: 254
    t.string "nat_level", limit: 254
    t.string "res_of_aut", limit: 254
    t.float "shape_area"
    t.float "shape_leng"
    t.bigint "shp_id"
    t.index ["geom"], name: "index_uat_boundaries_on_geom", using: :gist
    t.index ["name"], name: "index_uat_boundaries_on_name"
    t.index ["nat_code"], name: "index_uat_boundaries_on_nat_code"
  end

  add_foreign_key "building_common_parts", "buildings"
  add_foreign_key "buildings", "addresses"
  add_foreign_key "buildings", "lands"
  add_foreign_key "cgxml_validation_errors", "file_descriptions"
  add_foreign_key "cladiri_cadastrale", "parcele_cadastrale"
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
