require "open-uri"

class CgxmlValidationService
  XSD_URL        = "https://www.ancpi.ro/pnccf/documente/CGXMLSchema_new_v3.xsd".freeze
  XSD_CACHE_PATH = Rails.root.join("tmp", "ancpi_cgxml_v3.xsd").freeze

  # Dicționarele oficiale ANCPI extrase din kit-ul Generare CG (vezi
  # Cgxml::AncpiDictionaries). Aceste constants validează semantic câmpurile
  # tip „Dictionar" din XSD — XSD-ul însuși le declară `xs:string` fără
  # enumeration, dar aplicația oficială ANCPI verifică membership-ul.
  DICT = Cgxml::AncpiDictionaries

  # Placeholder universal în CGXML pentru valori lipsă/necunoscute. La import
  # `"_empty"` se transformă în NULL; `"-"` și `"_"` rămân ca string-uri și
  # marchează absența semantică a valorii. Nu le considerăm „prezente" pentru
  # check_present.
  MISSING_PLACEHOLDERS = %w[- _].freeze

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

    # Cele 62 reguli oficiale ANCPI (sub-set aplicabil fluxului) — ErrXX.
    @errors.concat(Cgxml::AncpiRules.new(@fd).call)

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

    check_present(fd, :filename, "Numele fișierului este obligatoriu")
    # fileversion / operationtype — opționale în practica reală (verificat pe Sascut
    # corectate: 189 fișiere nu au fileversion). Skip.
    check_present(fd, :operationtype, "Tipul operațiunii lipsește", severity: "warning")
    if fd.operationtype.present? && !DICT.in?(fd.operationtype, DICT::OPERATION_TYPES)
      add_field_error(fd, :operationtype, "INVALID_ENUM", "error",
        "Tipul operațiunii nu e recunoscut în dicționarul ANCPI OT_CAD",
        fd.operationtype, DICT::OPERATION_TYPES.join(" | "))
    end
    # licensedname / licensenumber se completează de prestator la EXPORT,
    # nu la import (fluxul nostru consumă fișiere intermediare). Nu raportăm.

    # EXPORTDATE e `minOccurs="0"` în XSD — opțional, nu obligatoriu.
    # (În practică ANCPI nu îl include în export — verificat pe 7900 fișiere.)
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
    # SIRUTA — opțional în practica reală (Sascut corectate: 60% nu îl au).
    # Verificare doar de format când e prezent.
    if addr.siruta.present? && !addr.siruta.match?(/\A\d{1,6}\z/)
      add_field_error(addr, :siruta, "INVALID_FORMAT", "error",
        "SIRUTA trebuie să fie numeric, max 6 cifre", addr.siruta, "1-6 cifre numerice")
    end

    if addr.sirsup.present? && !addr.sirsup.match?(/\A\d{1,6}\z/)
      add_field_error(addr, :sirsup, "INVALID_FORMAT", "error",
        "SIRSUP trebuie să fie numeric, max 6 cifre", addr.sirsup, "1-6 cifre numerice")
    end

    if addr.districttype.present? && !DICT.in?(addr.districttype, DICT::DISTRICT_TYPES)
      add_field_error(addr, :districttype, "INVALID_ENUM", "warning",
        "Tipul districtului nu e în dicționarul ANCPI DISTRICT",
        addr.districttype, DICT::DISTRICT_TYPES.join(" | "))
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

      # Diferența parcellegalarea vs measuredarea — acoperit de ERR26/35/36
      # din Cgxml::AncpiRules (cod ANCPI proper, nu BUSINESS_RULE generic).
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

        if bld.buildingdestination.present? && !DICT.in?(bld.buildingdestination, DICT::BUILDING_DESTINATIONS)
          add_field_error(bld, :buildingdestination, "INVALID_ENUM", "error",
            "Destinația construcției nu e în dicționarul ANCPI BUILDDEST",
            bld.buildingdestination, DICT::BUILDING_DESTINATIONS.join(" | "))
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
          if bcp.commonparttype.present? && !DICT.in?(bcp.commonparttype, DICT::COMMON_PART_TYPES)
            add_field_error(bcp, :commonparttype, "INVALID_ENUM", "warning",
              "Tipul părții comune nu e în dicționarul ANCPI COMMONPARTS",
              bcp.commonparttype, DICT::COMMON_PART_TYPES.first(8).join(" | ") + "…")
          end
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
        if parcel.usecategory.blank?
          add_field_error(parcel, :usecategory, "MISSING_REQUIRED", "warning",
            "Categoria de folosință lipsește — recomandată pentru cadastru",
            nil, DICT::USE_CATEGORIES.join(" | "))
        elsif !DICT.valid_usecategory?(parcel.usecategory)
          msg = if parcel.usecategory.include?("-")
                  "Categoria de folosință compusă (#{parcel.usecategory}) NU e acceptată de ANCPI — " \
                  "împărțiți parcela în două entități separate, fiecare cu propria categorie simplă"
                else
                  "Categoria de folosință nu e în dicționarul ANCPI USECAT"
                end
          add_field_error(parcel, :usecategory, "INVALID_ENUM", "error",
            msg, parcel.usecategory, DICT::USE_CATEGORIES.join(" | "))
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
      # În practică deednumber/authority lipsesc pentru acte vechi (TP-uri din
      # arhivă, certificate moștenitor fără număr scanat). Marcat ca warning,
      # nu error — fișierul rămâne valid, dar utilizatorul vede absența.
      check_present(deed, :deednumber, "Numărul actului lipsește", severity: "warning")
      check_present(deed, :deedtype,   "Tipul actului lipsește",   severity: "warning")
      check_present(deed, :authority,  "Emitentul actului lipsește", severity: "warning")

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
        if reg.registrationtype.present? && !DICT.in?(reg.registrationtype, DICT::REGISTRATION_TYPES)
          add_field_error(reg, :registrationtype, "INVALID_ENUM", "error",
            "Tipul înscrierii nu e în dicționarul ANCPI REGISTRATIONTYPE",
            reg.registrationtype, DICT::REGISTRATION_TYPES.join(" | "))
        end

        if reg.righttype.present? && !DICT.in?(reg.righttype, DICT::RIGHT_TYPES)
          add_field_error(reg, :righttype, "INVALID_ENUM", "warning",
            "Tipul dreptului nu e în dicționarul ANCPI RIGHTTYPE",
            reg.righttype, DICT::RIGHT_TYPES.first(8).join(" | ") + "…")
        end

        # appdate (data cererii) — relevantă DOAR la depunerea oficială.
        # Fișierele cadastru sistematic în lucru NU au appdate (verificat pe
        # Sascut: 80% lipsă). Skip raportarea.
      end
    end
  end

  def validate_persons
    @fd.persons.each do |person|
      # `firstname` poate lipsi pentru: persoane vechi din arhivă, decedați
      # fără identificare completă, mandatari. Demoted la warning.
      check_present(person, :firstname,
        "Prenumele/denumirea persoanei lipsește", severity: "warning")

      # Validare structurală CNP/CUI cu modulul dedicat — acceptă marker-urile
      # oficiale ANCPI 0×13 (UNIDENTIFIED) și 9×13 (necunoscut).
      if person.idcode.present?
        cls = Cgxml::CnpValidator.classify(person.idcode, is_physical: person.isphysical)
        sev = Cgxml::CnpValidator.severity_for(cls)
        msg = Cgxml::CnpValidator.message_for(cls)
        if sev && msg
          add_field_error(person, :idcode,
                          cls.to_s.upcase.start_with?("INVALID") ? "INVALID_FORMAT" : "BUSINESS_RULE",
                          sev, msg, person.idcode,
                          person.isphysical ? "CNP valid (13 cifre + checksum) sau 9999999999999" : "CUI valid (algoritm ANAF)")
        end
      end

      unless person.isphysical
        check_present(person, :lastname,
          "Denumirea persoanei juridice (LASTNAME) lipsește", severity: "warning")
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
    return if val.present? && !MISSING_PLACEHOLDERS.include?(val.to_s)

    add_field_error(record, field, "MISSING_REQUIRED", severity, message, val&.to_s, "Câmp completat")
  end

  # Helper rămas pentru viitor, dacă vrem dictionary lookups oficiale.
  # Momentan câmpurile-dicționar nu sunt validate semantic (vezi CGXML_DICTIONARY_FIELDS).
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
    # Doar erorile (severity='error') marchează fișierul ca invalid.
    # Warnings sunt informative — nu blochează validitatea.
    status = errs.zero? ? "valid" : "errors"

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
