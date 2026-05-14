class CgxmlImportService
  Result = Struct.new(:counts, :import_errors, :file_description, :partial, keyword_init: true) do
    def success?    = import_errors.empty?
    def partial?    = partial
    def total_saved = counts.values.sum
  end

  def initialize(xml_content, filename: "import.cgxml", content_hash: nil, file_description: nil)
    @xml_content  = xml_content
    @filename     = filename
    @content_hash = content_hash
    @doc         = nil
    @id_map      = {}
    @counts      = Hash.new(0)
    @import_errors = []
    # Dacă primim un stub (flux bulk async), îl refolosim în loc să creem unul nou.
    @file_description = file_description
    @prepopulated_fd  = !file_description.nil?
  end

  def call
    @doc = Nokogiri::XML(@xml_content) { |cfg| cfg.noblanks }

    import_file_descriptions
    import_addresses
    import_deeds
    import_lands
    import_buildings
    import_building_common_parts
    import_individual_units
    import_parcels
    import_registrations
    import_registration_x_entities
    import_points
    import_persons
    import_contesteds
    import_contested_x_entities
    dedupe_by_identifier

    finalize_file_description

    Result.new(
      counts:        @counts,
      import_errors: @import_errors,
      file_description: @file_description,
      partial: @import_errors.any?
    )
  rescue Nokogiri::XML::SyntaxError => e
    Result.new(
      counts: @counts,
      import_errors: [ { entity: "XML", message: "XML invalid: #{e.message}" } ],
      file_description: nil,
      partial: false
    )
  rescue => e
    Result.new(
      counts: @counts,
      import_errors: [ { entity: "Import", message: e.message } ],
      file_description: @file_description,
      partial: @counts.values.sum > 0
    )
  end

  private

  # ── XML helpers ──────────────────────────────────────────────────────────────

  def nodes(name) = @doc.xpath("//*[local-name()='#{name}']")

  def txt(node, field)
    val = node.at_xpath("*[local-name()='#{field}']")&.text&.strip
    val.presence == "_empty" ? nil : val.presence
  end

  def bool_val(node, field, default: nil)
    v = txt(node, field)
    return default if v.nil?
    %w[true 1].include?(v.downcase)
  end

  def float_val(node, field) = txt(node, field)&.to_f
  def int_val(node, field)   = txt(node, field)&.to_i

  def dt_val(node, field)
    v = txt(node, field)
    return nil unless v
    DateTime.parse(v) rescue nil
  end

  # ── ID mapping ───────────────────────────────────────────────────────────────

  def store_id(type, cgxml_id, db_id)
    @id_map["#{type}:#{cgxml_id}"] = db_id if cgxml_id
  end

  def mapped(type, cgxml_id)
    @id_map["#{type}:#{cgxml_id}"]
  end

  # ── Flexible save (savepoint per record) ────────────────────────────────────

  def safe_save(entity_type, attrs, &block)
    rec = nil
    ActiveRecord::Base.transaction(requires_new: true) do
      rec = block.call
      @counts[entity_type] += 1
    end
    rec
  rescue ActiveRecord::RecordInvalid => e
    @import_errors << { entity: entity_type, message: e.message, attrs: attrs.slice(:id) }
    nil
  rescue => e
    @import_errors << { entity: entity_type, message: e.message }
    nil
  end

  def finalize_file_description
    return unless @file_description

    status = @import_errors.any? ? "partial" : "done"
    @file_description.update_columns(
      import_status:       status,
      import_errors_count: @import_errors.size,
      raw_xml:             @xml_content.truncate(500_000),
      imported_at:         Time.current,
      content_hash:        @content_hash
    )
  end

  # ── Importers ────────────────────────────────────────────────────────────────

  def import_file_descriptions
    nodes("FileDescription").each do |n|
      cgxml_id = int_val(n, "FILEID")
      attrs = {
        filename:      (txt(n, "FILENAME") || @filename).to_s.first(50),
        exportdate:    dt_val(n, "EXPORTDATE"),
        fileversion:   txt(n, "FILEVERSION"),
        operationtype: txt(n, "OPERATIONTYPE"),
        licensedname:  txt(n, "LICENSEDNAME"),
        licensenumber: txt(n, "LICENSENUMBER")
      }

      # Flux bulk async: refolosește stub-ul deja existent pentru primul FileDescription
      # întâlnit; pentru orice FD suplimentar în același XML, cădem pe flux normal (create).
      if @prepopulated_fd && @file_description && cgxml_id && !@id_map.key?("FileDescription:#{cgxml_id}")
        @file_description.update!(attrs)
        store_id("FileDescription", cgxml_id, @file_description.id)
        @counts[:file_descriptions] += 1
        next
      end

      rec = safe_save(:file_descriptions, attrs) do
        FileDescription.create!(attrs.merge(import_status: "partial", imported_at: Time.current))
      end
      next unless rec

      store_id("FileDescription", cgxml_id, rec.id)
      @file_description ||= rec
    end

    # Fără FileDescription în XML: dacă avem stub, îl folosim; altfel creăm placeholder.
    if @file_description.nil?
      @file_description = FileDescription.create!(
        filename:      @filename,
        import_status: "partial",
        imported_at:   Time.current
      )
      @counts[:file_descriptions] += 1
    end
  end

  def import_addresses
    nodes("Address").each do |n|
      cgxml_id = int_val(n, "ADDRESSID")
      rec = safe_save(:addresses, { addressid: cgxml_id }) do
        Address.create!(
          sirsup:       txt(n, "SIRSUP"),
          siruta:       txt(n, "SIRUTA"),
          intravilan:   bool_val(n, "INTRAVILAN", default: false),
          districttype: txt(n, "DISTRICTTYPE"),
          districtname: txt(n, "DISTRICTNAME"),
          streettype:   txt(n, "STREETTYPE"),
          streetname:   txt(n, "STREETNAME"),
          postalnumber: txt(n, "POSTALNUMBER"),
          block:        txt(n, "BLOCK"),
          entry:        txt(n, "ENTRY"),
          floor:        txt(n, "FLOOR"),
          apno:         txt(n, "APNO"),
          zipcode:      txt(n, "ZIPCODE"),
          description:  txt(n, "DESCRIPTION"),
          section:      txt(n, "SECTION")
        )
      end
      store_id("Address", cgxml_id, rec.id) if rec
    end
  end

  def import_deeds
    nodes("Deed").each do |n|
      cgxml_id = int_val(n, "DEEDID")
      fd_id    = mapped("FileDescription", int_val(n, "FILEID")) || @file_description&.id
      rec = safe_save(:deeds, { deedid: cgxml_id }) do
        Deed.create!(
          file_description_id: fd_id,
          deednumber:   txt(n, "DEEDNUMBER") || "-",
          deeddate:     dt_val(n, "DEEDDATE"),
          deedtype:     txt(n, "DEEDTYPE") || "-",
          authority:    txt(n, "AUTHORITY") || "-",
          notes:        txt(n, "NOTES"),
          valuecurrency: txt(n, "VALUECURRENCY"),
          valueamount:  txt(n, "VALUEAMOUNT")
        )
      end
      store_id("Deed", cgxml_id, rec.id) if rec
    end
  end

  def import_lands
    nodes("Land").each do |n|
      cgxml_id = int_val(n, "LANDID")
      fd_id    = mapped("FileDescription", int_val(n, "FILEID")) || @file_description&.id
      rec = safe_save(:lands, { landid: cgxml_id }) do
        Land.create!(
          file_description_id: fd_id,
          address_id:          mapped("Address", int_val(n, "ADDRESSID")),
          cadsector:           txt(n, "CADSECTOR"),
          measuredarea:        float_val(n, "MEASUREDAREA") || 0.0,
          parcellegalarea:     float_val(n, "PARCELLEGALAREA"),
          buildinglegalarea:   float_val(n, "BUILDINGLEGALAREA"),
          taxvalue:            float_val(n, "TAXVALUE"),
          isnew:               bool_val(n, "ISNEW", default: true),
          notes:               txt(n, "NOTES"),
          enclosed:            bool_val(n, "ENCLOSED"),
          coarea:              bool_val(n, "COAREA"),
          e2identifier:        txt(n, "E2IDENTIFIER"),
          papercadno:          txt(n, "PAPERCADNO"),
          paperlbno:           txt(n, "PAPERLBNO"),
          topono:              txt(n, "TOPONO"),
          cadgenno:            txt(n, "CADGENNO")
        )
      end
      store_id("Land", cgxml_id, rec.id) if rec
    end
  end

  def import_buildings
    nodes("Building").each do |n|
      cgxml_id = int_val(n, "BUILDINGID")
      rec = safe_save(:buildings, { buildingid: cgxml_id }) do
        Building.create!(
          land_id:              mapped("Land", int_val(n, "LANDID")),
          address_id:           mapped("Address", int_val(n, "ADDRESSID")),
          buildno:              int_val(n, "BUILDNO") || 1,
          measuredarea:         float_val(n, "MEASUREDAREA") || 0.0,
          totalarea:            float_val(n, "TOTALAREA") || 0.0,
          buildingdestination:  txt(n, "BUILDINGDESTINATION"),
          levelsno:             int_val(n, "LEVELSNO"),
          iuno:                 int_val(n, "IUNO") || 0,
          taxvalue:             float_val(n, "TAXVALUE"),
          notes:                txt(n, "NOTES"),
          islegal:              bool_val(n, "ISLEGAL", default: true),
          legalarea:            float_val(n, "LEGALAREA"),
          e2identifier:         txt(n, "E2IDENTIFIER"),
          papercadno:           txt(n, "PAPERCADNO"),
          paperlbno:            txt(n, "PAPERLBNO"),
          topono:               txt(n, "TOPONO"),
          cadgenno:             txt(n, "CADGENNO")
        )
      end
      store_id("Building", cgxml_id, rec.id) if rec
    end
  end

  def import_building_common_parts
    nodes("BuildingCommonParts").each do |n|
      cgxml_id = int_val(n, "BUILDINGCOMMONPARTID")
      rec = safe_save(:building_common_parts, { id: cgxml_id }) do
        BuildingCommonPart.create!(
          building_id:    mapped("Building", int_val(n, "BUILDINGID")),
          commonparttype: txt(n, "COMMONPARTTYPE")
        )
      end
      store_id("BuildingCommonPart", cgxml_id, rec.id) if rec
    end
  end

  def import_individual_units
    nodes("IU").each do |n|
      cgxml_id = int_val(n, "IUID")
      rec = safe_save(:individual_units, { iuid: cgxml_id }) do
        IndividualUnit.create!(
          building_id:          mapped("Building", int_val(n, "BUILDINGID")),
          identifier:           txt(n, "IDENTIFIER") || "-",
          section:              txt(n, "SECTION"),
          apno:                 txt(n, "APNO"),
          entry:                txt(n, "ENTRY"),
          measuredarea:         float_val(n, "MEASUREDAREA"),
          totalarea:            float_val(n, "TOTALAREA"),
          landindivisionarea:   txt(n, "LANDINDIVISIONAREA"),
          commonpartsarea:      txt(n, "COMMONPARTSAREA"),
          notes:                txt(n, "NOTES"),
          floor:                txt(n, "FLOOR"),
          landdivisiontype:     txt(n, "LANDDIVISIONTYPE"),
          commonpartstype:      txt(n, "COMMONPARTSTYPE"),
          roomno:               int_val(n, "ROOMNO"),
          e2identifier:         txt(n, "E2IDENTIFIER"),
          papercadno:           txt(n, "PAPERCADNO"),
          paperlbno:            txt(n, "PAPERLBNO"),
          topono:               txt(n, "TOPONO"),
          cadgenno:             txt(n, "CADGENNO")
        )
      end
      store_id("IndividualUnit", cgxml_id, rec.id) if rec
    end
  end

  def import_parcels
    nodes("Parcel").each do |n|
      cgxml_id = int_val(n, "PARCELID")
      rec = safe_save(:parcels, { parcelid: cgxml_id }) do
        Parcel.create!(
          land_id:      mapped("Land", int_val(n, "LANDID")),
          number:       int_val(n, "NUMBER"),
          measuredarea: float_val(n, "MEASUREDAREA"),
          usecategory:  txt(n, "USECATEGORY"),
          intravilan:   bool_val(n, "INTRAVILAN"),
          taxvalue:     float_val(n, "TAXVALUE"),
          titleno:      txt(n, "TITLENO"),
          landplotno:   txt(n, "LANDPLOTNO"),
          parcelno:     txt(n, "PARCELNO"),
          notes:        txt(n, "NOTES"),
          e2identifier: txt(n, "E2IDENTIFIER"),
          papercadno:   txt(n, "PAPERCADNO"),
          paperlbno:    txt(n, "PAPERLBNO"),
          topono:       txt(n, "TOPONO"),
          cadgenno:     txt(n, "CADGENNO")
        )
      end
      store_id("Parcel", cgxml_id, rec.id) if rec
    end
  end

  def import_registrations
    nodes("Registration").each do |n|
      cgxml_id = int_val(n, "REGISTRATIONID")
      rec = safe_save(:registrations, { registrationid: cgxml_id }) do
        Registration.create!(
          deed_id:          mapped("Deed", int_val(n, "DEEDID")),
          registrationtype: txt(n, "REGISTRATIONTYPE") || "-",
          righttype:        txt(n, "RIGHTTYPE"),
          rightcomment:     txt(n, "RIGHTCOMMENT"),
          notes:            txt(n, "NOTES"),
          title:            txt(n, "TITLE"),
          quotatype:        txt(n, "QUOTATYPE"),
          initialquota:     txt(n, "INITIALQUOTA"),
          actualquota:      txt(n, "ACTUALQUOTA"),
          valuecurrency:    txt(n, "VALUECURRENCY"),
          valueamount:      txt(n, "VALUEAMOUNT"),
          comments:         txt(n, "COMMENTS"),
          lbpartno:         int_val(n, "LBPARTNO"),
          position:         int_val(n, "POSITION"),
          appno:            int_val(n, "APPNO"),
          appdate:          dt_val(n, "APPDATE")
        )
      end
      store_id("Registration", cgxml_id, rec.id) if rec
    end
  end

  def import_registration_x_entities
    nodes("RegistrationXEntity").each do |n|
      safe_save(:registration_x_entities, {}) do
        RegistrationXEntity.create!(
          registration_id:    mapped("Registration",  int_val(n, "REGISTRATIONID")),
          land_id:            mapped("Land",           int_val(n, "LANDID")),
          building_id:        mapped("Building",       int_val(n, "BUILDINGID")),
          individual_unit_id: mapped("IndividualUnit", int_val(n, "IUID"))
        )
      end
    end
  end

  def import_points
    factory = RGeo::Cartesian.factory(srid: 3844)
    nodes("Points").each do |n|
      cgxml_id = int_val(n, "POINTID")
      x = float_val(n, "X")
      y = float_val(n, "Y")
      coords = (x && y) ? factory.point(x, y) : nil
      rec = safe_save(:points, { pointid: cgxml_id }) do
        Point.create!(
          land_id:     mapped("Land",     int_val(n, "IMMOVABLEID")),
          building_id: mapped("Building", int_val(n, "BUILDINGID")),
          no:          txt(n, "NO"),
          x:           x,
          y:           y,
          coordinates: coords
        )
      end
      store_id("Point", cgxml_id, rec.id) if rec
    end
  end

  def import_persons
    nodes("Person").each do |n|
      cgxml_id = int_val(n, "PERSONID")
      fd_id    = mapped("FileDescription", int_val(n, "FILEID")) || @file_description&.id
      rec = safe_save(:persons, { personid: cgxml_id }) do
        Person.create!(
          address_id:          mapped("Address",       int_val(n, "ADDRESSID")),
          file_description_id: fd_id,
          registration_id:     mapped("Registration",  int_val(n, "REGISTRATIONID")),
          firstname:           txt(n, "FIRSTNAME") || "-",
          isphysical:          bool_val(n, "ISPHYSICAL", default: true),
          lastname:            txt(n, "LASTNAME"),
          defunct:             bool_val(n, "DEFUNCT"),
          identified:          bool_val(n, "IDENTIFIED"),
          idcode:              txt(n, "IDCODE"),
          previouslastname:    txt(n, "PREVIOUSLASTNAME"),
          fatherinitial:       txt(n, "FATHERINITIAL"),
          citizenshipcountry:  txt(n, "CITIZENSHIPCOUNTRY"),
          idcardtype:          txt(n, "IDCARDTYPE"),
          idcardserialno:      txt(n, "IDCARDSERIALNO"),
          idcardnumber:        txt(n, "IDCARDNUMBER"),
          notes:               txt(n, "NOTES"),
          phone:               txt(n, "PHONE"),
          email:               txt(n, "EMAIL")
        )
      end
      store_id("Person", cgxml_id, rec.id) if rec
    end
  end

  def import_contesteds
    nodes("Contested").each do |n|
      cgxml_id = int_val(n, "CONTESTEDID")
      rec = safe_save(:contesteds, { contestedid: cgxml_id }) do
        Contested.create!(
          contestednumber: int_val(n, "CONTESTEDNUMBER"),
          contesteddate:   dt_val(n, "CONTESTEDDATE"),
          solutionnumber:  int_val(n, "SOLUTIONNUMBER"),
          solutiondate:    dt_val(n, "SOLUTIONDATE")
        )
      end
      store_id("Contested", cgxml_id, rec.id) if rec
    end
  end

  def import_contested_x_entities
    nodes("ContestedxEntity").each do |n|
      safe_save(:contested_x_entities, {}) do
        ContestedXEntity.create!(
          contested_id:       mapped("Contested",     int_val(n, "CONTESTEDID")),
          land_id:            mapped("Land",           int_val(n, "LANDID")),
          building_id:        mapped("Building",       int_val(n, "BUILDINGID")),
          individual_unit_id: mapped("IndividualUnit", int_val(n, "IUID"))
        )
      end
    end
  end

  # Dedup post-import: pentru fiecare Land/Building tocmai importat, găsim
  # rândurile MAI VECHI cu același cadgenno SAU e2identifier (identificatori
  # business) și le ȘTERGEM (împreună cu Points-urile lor). Astfel ultima
  # versiune importată ia locul vechii.
  def dedupe_by_identifier
    fd_id = @file_description&.id
    return unless fd_id

    # Lands
    Land.where(file_description_id: fd_id).find_each do |new_land|
      cad = new_land.cadgenno.presence
      e2  = new_land.e2identifier.presence
      next if cad.nil? && e2.nil?

      old_lands = Land.where.not(id: new_land.id)
                       .where("(cadgenno IS NOT NULL AND cadgenno = ?) OR (e2identifier IS NOT NULL AND e2identifier = ?)",
                              cad, e2)
      old_lands.find_each do |old|
        # Cascade: ștergem clădirile asociate vechiului land + punctele lor
        Building.where(land_id: old.id).find_each do |b|
          Point.where(building_id: b.id).delete_all
          b.delete
        end
        Point.where(land_id: old.id).delete_all
        old.delete
      end
    end

    # Buildings (independent — pot avea identificatori distincti)
    Building.joins(:land).where(lands: { file_description_id: fd_id }).find_each do |new_b|
      cad = new_b.cadgenno.presence
      e2  = new_b.e2identifier.presence
      next if cad.nil? && e2.nil?

      old_b = Building.where.not(id: new_b.id)
                       .where("(cadgenno IS NOT NULL AND cadgenno = ?) OR (e2identifier IS NOT NULL AND e2identifier = ?)",
                              cad, e2)
      old_b.find_each do |old|
        Point.where(building_id: old.id).delete_all
        old.delete
      end
    end
  end
end
