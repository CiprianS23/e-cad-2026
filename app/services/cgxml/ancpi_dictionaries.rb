module Cgxml
  # Dicționarele oficiale ANCPI extrase din kit-ul „Generare CG" v1.0.0.7
  # (sursă: tmp/ancpi_kit/Dictionary.xml + RightType.xml; copia YAML completă
  # în config/ancpi_cgxml_dictionaries.yml).
  #
  # Aceste constants substituie enum-urile ghicite vechi din CgxmlValidationService.
  # Valorile sunt EXACT cele din aplicația oficială ANCPI; orice valoare în afara
  # acestor liste reprezintă o eroare reală în fișierul cgxml (sau o extensie
  # ulterioară din ANCPI pe care trebuie să o sincronizăm cu un kit mai nou).
  module AncpiDictionaries
    # BUILDDEST — destinația construcției (Building.buildingdestination)
    BUILDING_DESTINATIONS = %w[CA CAS CIE CL].freeze

    # USECAT — categoria de folosință (Parcel.usecategory)
    # ATENȚIE: ANCPI acceptă DOAR codurile simple din această listă. Valori
    # compuse („DR-N", „HR-C", „V-HB", „P-C", „HR-S") întâlnite în date reale
    # SUNT erori — provin din migrări legacy sau introducere greșită și trebuie
    # corectate manual la introducerea în cadastru sistematic.
    USE_CATEGORIES = %w[A ALTELE CC CF DR F HB HR L N NA P PD V].freeze

    # REGISTRATIONTYPE — tipul înscrierii în CF (Registration.registrationtype)
    REGISTRATION_TYPES = %w[INTAB NOTATION POSESION_REGISTATION PROVISIONALENTRY].freeze

    # RIGHTTYPE — tipul dreptului (Registration.righttype). 18 valori, incl. multi-word.
    RIGHT_TYPES = [
      "ADMINISTRARE", "COMODAT", "CONCESIUNE", "FOLOSINTA",
      "FOLOSINTA CU TITLU GRATUIT", "FOLOSINTA SPECIALA", "HABITATIE",
      "INCHIRIERE", "IPOTECA", "IPOTECA LEGALA", "LEASING IMOBILIAR",
      "PRIVILEGIU IMOBILIAR", "PROPRIETATE", "SERVITUTE", "SUPERFICIE",
      "UZ", "UZUFRUCT", "UZUFRUCT VIAGER"
    ].freeze

    # DOCT — tipul documentului / actului (Deed.deedtype, parțial)
    # NOTĂ: în date reale apar și valori NEPREZENTE în acest dicționar (ex.
    # CONTRACT_VANZARE-CUMPARARE, REGISTRUL_CADASTRAL_AL_IMOBILELOR, CERTIFICAT_MOSTENITOR,
    # CONTRACT_DE_PARTAJ_1130, ACT_NORMATIV, ACT_NOTARIAL, etc.). Aceasta sugerează
    # că DOCT din kit e o sub-listă a unui dicționar extins. NU validăm strict deedtype.
    DOC_TYPES = %w[
      ACTIUNE_INSTANTA ACT_NORMATIV ACT_NOTARIAL ADMINISTRATIVE_1
      CERTIFICAT_GREFA1 FISA_INTERVIU HOTARARE_JUDECATOREASCA
      INSCRIS_SUB_SEMNATURA_PRIVATA ORDONANTA SOMATIE
    ].freeze

    # COMMONPARTS — tipuri părți comune ale clădirii (BuildingCommonPart.commonparttype)
    COMMON_PART_TYPES = %w[
      ACOPERIS ALTE_SPATII BALCON BOXA CAMERA_TEHNICA CASA_ASCENSORULUI
      CASA_SCARII CENTRALA_TERMICA COS_FUM DUSURI_COMUNE GHENA HOLURI
      LOGIE PIVNITA POD RAMPA_ACCES SCARA_ACCES SCARI_EXTERIOARE
      SPALATORIE SUBSOL TERASA USCATORIE
    ].freeze

    # IDCARDTYPE — tipul actului de identitate (Person.idcardtype)
    ID_CARD_TYPES = %w[BI CI PASS].freeze

    # ITYPE — tipul imobilului (Land/Building/IU contextual)
    IMMOVABLE_TYPES = %w[APARTMENT BUILDING LAND].freeze

    # OT_CAD — tipul operațiunii cadastrale individuale (FileDescription.operationtype)
    # NOTĂ: pe lângă acestea, fluxul mass-import „General Cadastre" (PNCCF) folosește
    # valoarea GENERAL_CADASTRE care NU e în OT_CAD. O adăugăm explicit ca extensie.
    OPERATION_TYPES_INDIVIDUAL = %w[
      AMALGAMATION CREATE_UI DISMEMBER DISMEMBER_AMALGAMATION_UI
      FIRST_REGISTRATION FIRST_REGISTRATION_UI RECREATE_UI
      RECTIFY_BOUNDARIES UPDATE_DATA_LAND UPDATE_DATA_UI
    ].freeze
    OPERATION_TYPES_BULK = %w[GENERAL_CADASTRE].freeze
    OPERATION_TYPES = (OPERATION_TYPES_INDIVIDUAL + OPERATION_TYPES_BULK).freeze

    # QUOTA_TYPE — tipul cotei
    QUOTA_TYPES = %w[ABSOLUTE_QUOTA FRACTION_QUOTA PERCENTAGE_QUOTA].freeze

    # DISTRICT — tipul tarlalei/cvartalului (Address.districttype)
    DISTRICT_TYPES = %w[CAR CART CVART MICRO].freeze

    # TITLETYPE — tipul titlului juridic
    TITLE_TYPES = %w[
      ACCESIUNE CONSTITUIRE CONSTRUIRE CONVENTIE EXPROPRIERE HOTARARE
      IESIRE_INDIVIZIUNE LEGE SUCCESIUNE UZUCAPIUNE
    ] + %w[adjudecare reconstituire]  # primele cu majusculă, ultimele cu minusculă în dicționar
    TITLE_TYPES.freeze

    # ST — tipul căii (street type) — abreviere pentru tipul de drum/stradă
    STREET_TYPES = %w[
      AL BDUL CALEA CAREU DRUMUL FND FNDC INTR PIATA PREL PSJ SOS
      SPLAIUL STR STRADELA STRD ZONA
    ].freeze

    # CURRENCY — coduri monedă (ISO + istorice românești)
    CURRENCIES = %w[ATS CAD CHF DEM DKK EIR EUR GBP HUF INT JPY LEI ROL RON TRY USD].freeze

    # COUNTRY — coduri ISO 3166-1 alpha-2 (240 țări). Lipsesc detaliile aici;
    # le încărcăm lazy din YAML când e nevoie pentru validare adresă.
    def self.countries
      @countries ||= YAML.load_file(Rails.root.join("config/ancpi_cgxml_dictionaries.yml"))["COUNTRY"]
                         .map { |h| h["code"] }.freeze
    end

    # Validează strict — DOAR coduri simple din USECAT. Valorile compuse cu „-"
    # (DR-N, V-HB, HR-C, P-C, HR-S etc.) sunt RESPINSE; sunt erori în date care
    # trebuie corectate prin împărțirea parcelei în două entități separate.
    def self.valid_usecategory?(val)
      return false if val.blank?
      USE_CATEGORIES.include?(val.to_s.upcase.strip)
    end

    # Placeholder-uri „missing" comune în export ANCPI — tratate ca blank.
    MISSING_PLACEHOLDERS = %w[- _].freeze

    # Validare case-insensitive cu tolerare spațiu pentru câmpuri-dicționar simple.
    # Returnează true și pentru blank / placeholder „missing" (le tratează ca absente,
    # nu ca valori invalide).
    def self.in?(val, allowed)
      return true if val.blank?
      norm = val.to_s.upcase.strip
      return true if MISSING_PLACEHOLDERS.include?(norm)
      allowed.map { |a| a.to_s.upcase.strip }.include?(norm)
    end
  end
end
