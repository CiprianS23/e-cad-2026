require "open-uri"

class CgxmlValidationService
  XSD_URL        = "https://www.ancpi.ro/pnccf/documente/CGXMLSchema_new_v3.xsd".freeze
  XSD_CACHE_PATH = Rails.root.join("tmp", "ancpi_cgxml_v3.xsd").freeze

  # ── Enumeration constants from CGXML v3 XSD ────────────────────────────────
  USE_CATEGORIES = %w[
    AR CC L LI PA PA1 PA2 VI VD BI DR CF
    NE A PD PS AL NV FN
  ].freeze

  OPERATION_TYPES = %w[1 2 3].freeze

  BUILDING_DESTINATIONS = %w[
    L C1 C2 I A S CA CU E T O SP DP
  ].freeze

  DISTRICT_TYPES = %w[
    CARTIER ZONA TRUP INSULA INCINTA SECTOR FERMA PARCELA
  ].freeze

  RIGHT_TYPES = %w[
    PROPRIETATE ADMINISTRARE CONCESIUNE FOLOSINTA SUPERFICIE
    UZUFRUCT ABITATIE SERVITUTE IPOTECA PRIVILEGIU LOCATIUNE
  ].freeze

  REGISTRATION_TYPES = %w[
    B C1 C2 C3 C4 C5 C6 C7 C8 C9 C10 C11 C12 C13 C14 C15
    D1 D2 E1 E2 E3 F1 F2 G1 G2 G3
  ].freeze

  Result = Struct.new(:errors_count, :warnings_count, :xsd_valid, :errors, keyword_init: true)

  def initialize(file_description)
    @fd     = file_description
    @errors = []
  end

  def call
    @fd.update_columns(validation_status: "in_progress")
    @fd.cgxml_validation_errors.delete_all

    run_xsd_validation
    validate_file_description
    validate_addresses
    validate_lands
    validate_buildings
    validate_building_common_parts
    validate_individual_units
    validate_parcels
    validate_deeds
    validate_registrations
    validate_persons
    validate_points

    save_errors
    update_status

    Result.new(
      errors_count:   @errors.count { |e| e[:severity] == "error" },
      warnings_count: @errors.count { |e| e[:severity] == "warning" },
      xsd_valid:      @xsd_valid,
      errors:         @errors
    )
  end

  private

  # ── XSD validation ──────────────────────────────────────────────────────────

  def run_xsd_validation
    return unless @fd.raw_xml.present?

    schema = load_xsd_schema
    return unless schema

    xml_doc = Nokogiri::XML(@fd.raw_xml)
    schema_errors = schema.validate(xml_doc)
    @xsd_valid = schema_errors.empty?

    schema_errors.first(50).each do |err|
      add_error(
        entity_type: "FileDescription",
        entity_id:   @fd.id,
        field_name:  nil,
        error_code:  "XSD_VIOLATION",
        severity:    "error",
        message:     err.message,
        xpath:       err.path,
        current_value: nil,
        expected_format: "Schema ANCPI CGXMLSchema_new_v3.xsd"
      )
    end
  rescue => e
    Rails.logger.warn "[CgxmlValidation] XSD validation skipped: #{e.message}"
    @xsd_valid = nil
  end

  def load_xsd_schema
    if XSD_CACHE_PATH.exist? && XSD_CACHE_PATH.mtime > 7.days.ago
      Nokogiri::XML::Schema(XSD_CACHE_PATH.read)
    else
      fetch_and_cache_xsd
    end
  rescue => e
    Rails.logger.warn "[CgxmlValidation] Cannot load XSD: #{e.message}"
    nil
  end

  def fetch_and_cache_xsd
    xsd_content = URI.open(XSD_URL, read_timeout: 10).read
    FileUtils.mkdir_p(XSD_CACHE_PATH.dirname)
    XSD_CACHE_PATH.write(xsd_content)
    Nokogiri::XML::Schema(xsd_content)
  rescue => e
    Rails.logger.warn "[CgxmlValidation] Cannot fetch XSD from ANCPI: #{e.message}"
    nil
  end

  # ── Entity validators ───────────────────────────────────────────────────────

  def validate_file_description
    fd = @fd

    check_present(fd, :filename,      "Numele fișierului este obligatoriu")
    check_present(fd, :fileversion,   "Versiunea fișierului lipsește", severity: "warning")
    check_present(fd, :operationtype, "Tipul operațiunii lipsește")
    check_enum(fd, :operationtype, OPERATION_TYPES,
      "Tipul operațiunii trebuie să fie 1 (nou), 2 (actualizare) sau 3 (ștergere)")
    check_present(fd, :licensedname,   "Numele titular licență lipsește", severity: "warning")
    check_present(fd, :licensenumber,  "Numărul licenței lipsește",       severity: "warning")

    if fd.exportdate.nil?
      add_field_error(fd, :exportdate, "MISSING_REQUIRED", "error",
        "Data exportului este obligatorie", nil, "DateTime ISO8601")
    end
  end

  def validate_addresses
    @fd.lands.includes(:address).each do |land|
      validate_address(land.address) if land.address
    end
    @fd.persons.includes(:address).each do |person|
      validate_address(person.address) if person.address
    end
  end

  def validate_address(addr)
    check_present(addr, :siruta,
      "Codul SIRUTA al localității lipsește — necesar pentru identificarea UAT",
      severity: "warning")

    if addr.siruta.present? && !addr.siruta.match?(/\A\d{1,6}\z/)
      add_field_error(addr, :siruta, "INVALID_FORMAT", "error",
        "SIRUTA trebuie să fie numeric, max 6 cifre", addr.siruta, "1-6 cifre numerice")
    end

    if addr.sirsup.present? && !addr.sirsup.match?(/\A\d{1,6}\z/)
      add_field_error(addr, :sirsup, "INVALID_FORMAT", "error",
        "SIRSUP trebuie să fie numeric, max 6 cifre", addr.sirsup, "1-6 cifre numerice")
    end

    if addr.districttype.present?
      check_enum(addr, :districttype, DISTRICT_TYPES,
        "Tipul tarlalei/districtului are valoare nerecunoscută")
    end
  end

  def validate_lands
    @fd.lands.each do |land|
      if land.measuredarea.nil? || land.measuredarea < 0
        add_field_error(land, :measuredarea, "INVALID_RANGE", "error",
          "Suprafața măsurată trebuie să fie ≥ 0",
          land.measuredarea&.to_s, "Număr ≥ 0")
      end

      if land.measuredarea == 0.0
        add_field_error(land, :measuredarea, "BUSINESS_RULE", "warning",
          "Suprafața măsurată este 0 — verificați dacă este corect",
          "0", "Valoare pozitivă recomandată")
      end

      if land.parcellegalarea.present? && land.measuredarea.present? &&
         land.measuredarea > 0 &&
         (land.parcellegalarea - land.measuredarea).abs / land.measuredarea > 0.05
        add_field_error(land, :parcellegalarea, "BUSINESS_RULE", "warning",
          "Diferența dintre suprafața măsurată și suprafața legală depășește 5%",
          land.parcellegalarea.to_s,
          "Apropiată de suprafața măsurată (#{land.measuredarea})")
      end
    end
  end

  def validate_buildings
    @fd.lands.includes(:buildings).each do |land|
      land.buildings.each do |bld|
        if bld.buildno < 1
          add_field_error(bld, :buildno, "INVALID_RANGE", "error",
            "Numărul construcției trebuie să fie ≥ 1", bld.buildno.to_s, "Întreg ≥ 1")
        end

        if bld.measuredarea < 0
          add_field_error(bld, :measuredarea, "INVALID_RANGE", "error",
            "Suprafața măsurată a construcției nu poate fi negativă",
            bld.measuredarea.to_s, "Număr ≥ 0")
        end

        if bld.totalarea < 0
          add_field_error(bld, :totalarea, "INVALID_RANGE", "error",
            "Suprafața totală a construcției nu poate fi negativă",
            bld.totalarea.to_s, "Număr ≥ 0")
        end

        if bld.buildingdestination.present?
          check_enum(bld, :buildingdestination, BUILDING_DESTINATIONS,
            "Destinația construcției are valoare nerecunoscută conform CGXML v3")
        end

        if bld.levelsno.present? && bld.levelsno < 0
          add_field_error(bld, :levelsno, "INVALID_RANGE", "error",
            "Numărul de niveluri nu poate fi negativ", bld.levelsno.to_s, "Întreg ≥ 0")
        end
      end
    end
  end

  def validate_building_common_parts
    @fd.lands.includes(buildings: :building_common_parts).each do |land|
      land.buildings.each do |bld|
        bld.building_common_parts.each do |bcp|
          check_present(bcp, :commonparttype,
            "Tipul părții comune lipsește — câmp obligatoriu conform XSD")
        end
      end
    end
  end

  def validate_individual_units
    @fd.lands.includes(buildings: :individual_units).each do |land|
      land.buildings.each do |bld|
        bld.individual_units.each do |iu|
          check_present(iu, :identifier, "Identificatorul unității individuale este obligatoriu")

          if iu.measuredarea.present? && iu.measuredarea < 0
            add_field_error(iu, :measuredarea, "INVALID_RANGE", "error",
              "Suprafața unității individuale nu poate fi negativă",
              iu.measuredarea.to_s, "Număr ≥ 0")
          end
        end
      end
    end
  end

  def validate_parcels
    @fd.lands.includes(:parcels).each do |land|
      land.parcels.each do |parcel|
        if parcel.usecategory.present?
          check_enum(parcel, :usecategory, USE_CATEGORIES,
            "Categoria de folosință are valoare nerecunoscută conform CGXML v3 — " \
            "valori acceptate: #{USE_CATEGORIES.join(', ')}")
        else
          add_field_error(parcel, :usecategory, "MISSING_REQUIRED", "warning",
            "Categoria de folosință lipsește — recomandată pentru cadastru",
            nil, USE_CATEGORIES.join(" | "))
        end

        if parcel.measuredarea.present? && parcel.measuredarea < 0
          add_field_error(parcel, :measuredarea, "INVALID_RANGE", "error",
            "Suprafața parcelei nu poate fi negativă",
            parcel.measuredarea.to_s, "Număr ≥ 0")
        end
      end
    end
  end

  def validate_deeds
    @fd.deeds.each do |deed|
      check_present(deed, :deednumber,
        "Numărul actului este obligatoriu conform XSD")
      check_present(deed, :deedtype,
        "Tipul actului este obligatoriu conform XSD")
      check_present(deed, :authority,
        "Emitentul actului este obligatoriu conform XSD")

      if deed.deeddate.nil?
        add_field_error(deed, :deeddate, "MISSING_REQUIRED", "warning",
          "Data actului lipsește — recomandată pentru verificarea valabilității",
          nil, "DateTime ISO8601")
      end
    end
  end

  def validate_registrations
    @fd.deeds.includes(:registrations).each do |deed|
      deed.registrations.each do |reg|
        check_present(reg, :registrationtype,
          "Tipul înscrierii este obligatoriu conform XSD")

        if reg.registrationtype.present?
          check_enum(reg, :registrationtype, REGISTRATION_TYPES,
            "Tipul înscrierii are valoare nerecunoscută conform schema ANCPI")
        end

        if reg.righttype.present?
          check_enum(reg, :righttype, RIGHT_TYPES,
            "Tipul dreptului are valoare nerecunoscută conform schema ANCPI")
        end

        if reg.appdate.nil?
          add_field_error(reg, :appdate, "MISSING_REQUIRED", "warning",
            "Data cererii lipsește", nil, "DateTime ISO8601")
        end
      end
    end
  end

  def validate_persons
    @fd.persons.each do |person|
      check_present(person, :firstname, "Prenumele/denumirea persoanei este obligatorie")

      if person.isphysical
        if person.idcode.present? && person.idcode.length != 13
          add_field_error(person, :idcode, "INVALID_FORMAT", "error",
            "CNP-ul trebuie să aibă exact 13 cifre",
            person.idcode, "13 cifre numerice")
        end

        if person.idcode.present? && !person.idcode.match?(/\A\d{13}\z/)
          add_field_error(person, :idcode, "INVALID_FORMAT", "error",
            "CNP-ul poate conține doar cifre",
            person.idcode, "13 cifre numerice")
        end

        if person.idcode.present? && !valid_cnp_checksum?(person.idcode)
          add_field_error(person, :idcode, "BUSINESS_RULE", "warning",
            "Cifra de control a CNP-ului nu este validă — posibil CNP eronat",
            person.idcode, "CNP valid conform algoritmului ANAF")
        end
      else
        check_present(person, :lastname,
          "Denumirea persoanei juridice (câmpul LASTNAME) este obligatorie")
      end

      if person.email.present? && !person.email.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
        add_field_error(person, :email, "INVALID_FORMAT", "error",
          "Adresa de email nu are format valid",
          person.email, "exemplu@domeniu.ro")
      end
    end
  end

  def validate_points
    @fd.lands.includes(:points).each do |land|
      land.points.each do |pt|
        if pt.x.nil? || pt.y.nil?
          add_field_error(pt, :x, "MISSING_REQUIRED", "error",
            "Coordonatele punctului (X, Y) sunt obligatorii",
            nil, "Număr real în sistemul Stereo 70 / EPSG:3844")
        else
          # România: X în [200000..900000], Y în [100000..900000] (Stereo 70)
          unless (200_000..900_000).cover?(pt.x)
            add_field_error(pt, :x, "INVALID_RANGE", "warning",
              "Coordonata X pare în afara teritoriului României (Stereo 70)",
              pt.x.to_s, "200000–900000")
          end
          unless (100_000..900_000).cover?(pt.y)
            add_field_error(pt, :y, "INVALID_RANGE", "warning",
              "Coordonata Y pare în afara teritoriului României (Stereo 70)",
              pt.y.to_s, "100000–900000")
          end
        end
      end
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  def check_present(record, field, message, severity: "error")
    val = record.public_send(field)
    return if val.present? && val.to_s != "-"

    add_field_error(record, field, "MISSING_REQUIRED", severity, message, val&.to_s, "Câmp completat")
  end

  def check_enum(record, field, allowed, message, severity: "error")
    val = record.public_send(field)
    return if val.blank? || allowed.include?(val.to_s.upcase)

    add_field_error(record, field, "INVALID_ENUM", severity,
      message, val.to_s, allowed.join(" | "))
  end

  def add_field_error(record, field, code, severity, message, current, expected)
    add_error(
      entity_type:     record.class.name,
      entity_id:       record.id,
      field_name:      field.to_s,
      error_code:      code,
      severity:        severity,
      message:         message,
      current_value:   current,
      expected_format: expected,
      xpath:           nil
    )
  end

  def add_error(entity_type:, entity_id:, field_name:, error_code:, severity:,
                message:, current_value: nil, expected_format: nil, xpath: nil)
    @errors << {
      file_description_id: @fd.id,
      entity_type:         entity_type,
      entity_id:           entity_id,
      field_name:          field_name,
      error_code:          error_code,
      severity:            severity,
      error_message:       message,
      current_value:       current_value&.to_s&.truncate(255),
      expected_format:     expected_format&.truncate(255),
      xpath:               xpath
    }
  end

  def save_errors
    @errors.each_slice(100) do |batch|
      CgxmlValidationError.insert_all!(batch)
    end
  end

  def update_status
    errs  = @errors.count { |e| e[:severity] == "error" }
    warns = @errors.count { |e| e[:severity] == "warning" }
    status = (errs + warns).zero? ? "valid" : "errors"

    @fd.update_columns(
      validation_status:         status,
      validation_errors_count:   errs,
      validation_warnings_count: warns
    )
  end

  # ── CNP checksum ────────────────────────────────────────────────────────────

  CNP_WEIGHTS = [ 2, 7, 9, 1, 4, 6, 3, 5, 8, 2, 7, 9 ].freeze

  def valid_cnp_checksum?(cnp)
    return false unless cnp.match?(/\A\d{13}\z/)

    digits = cnp.chars.map(&:to_i)
    sum    = digits[0..11].zip(CNP_WEIGHTS).sum { |d, w| d * w }
    check  = sum % 11
    check  = 1 if check == 10
    digits[12] == check
  end
end
