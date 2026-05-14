module Cgxml
  # Regulile oficiale ANCPI extrase din ValidariCP.xml (tmp/ancpi_kit/). Fiecare
  # metodă publică validează O regulă (cod ERR1..ERR62) și acumulează erori în
  # @errors prin add_error. Codurile sunt identice cu cele din aplicația oficială
  # ANCPI Generare CG, ca să poată fi cross-referențate cu documentația.
  #
  # ── APLICABILITATE ───────────────────────────────────────────────────────────
  # Multe reguli sunt operation-flow-specifice (FIRST_REGISTRATION, DISMEMBER,
  # AMALGAMATION, CREATE_UI etc.) și NU se aplică fluxului mass-import
  # GENERAL_CADASTRE pe care îl primim. Vezi RULES_BY_FLOW pentru filtru.
  class AncpiRules
    # Reguli care se aplică indiferent de OPERATIONTYPE (inclusiv GENERAL_CADASTRE).
    UNIVERSAL_RULES = %w[
      ERR1 ERR2 ERR3 ERR11 ERR13 ERR15 ERR16 ERR22 ERR23 ERR24 ERR25
      ERR27 ERR31 ERR33 ERR35 ERR36 ERR37 ERR38 ERR39 ERR41 ERR43
      ERR45 ERR46 ERR47 ERR48 ERR49 ERR52 ERR53 ERR54 ERR56 ERR58
      ERR61 ERR62
    ].freeze
    # ── EXCLUDE după analiza comparativă Sascut corectate vs OCPI sporadic: ──
    #   ERR19 (parcela.taxvalue lipsește)      → 99.5% Sascut, taxvalue opțional
    #   ERR20 (building.taxvalue lipsește)     → la fel, opțional
    #   ERR21 (building.legalarea lipsește)    → opțional în practică
    #   ERR55 (cadsector)                      → completat de prestator la export
    #   ERR57 (postalnumber)                   → 76.9% Sascut îl omit
    #   ERR60 (zipcode)                        → mereu lipsă în cgxml, irrelevant
    #   ERR26/35/36 cu BUSINESS_RULE pe parcellegalarea → demoted la 5% strict

    # ERR100+ — reguli de corelație Registration descoperite empiric din
    # analiza celor 7904 fișiere cgxml import (vezi commit message pentru detalii).
    REGISTRATION_CORRELATION_RULES = %w[
      ERR100 ERR101 ERR102 ERR103 ERR104 ERR105 ERR106 ERR107 ERR108
      ERR109 ERR110 ERR111 ERR112 ERR113 ERR114 ERR116 ERR117 ERR118 ERR119
    ].freeze

    # Combinații deed_type → registration_type permise (≥30 cazuri în date reale).
    DEED_TO_REGTYPE = {
      "REGISTRUL_CADASTRAL_AL_IMOBILELOR" => %w[NOTATION],
      "INSCRIS_SUB_SEMNATURA_PRIVATA"     => %w[NOTATION],
      "SOMATIE"                            => %w[NOTATION],
      "ACT_NORMATIV"                       => %w[INTAB NOTATION PROVISIONALENTRY],
      "ACT_NOTARIAL"                       => %w[INTAB NOTATION],
      "ADMINISTRATIVE_1"                   => %w[INTAB NOTATION PROVISIONALENTRY],
      "CERTIFICAT_MOSTENITOR"              => %w[INTAB],
      "CONTRACT_DE_PARTAJ_1130"            => %w[INTAB],
      "CONTRACT_VANZARE-CUMPARARE"         => %w[INTAB NOTATION],
      "CVC"                                => %w[INTAB],
      "HOTARARE_JUDECATOREASCA"            => %w[INTAB NOTATION],
      "LEGE"                               => %w[INTAB PROVISIONALENTRY],
      "TITLU PROPRIETATE"                  => %w[INTAB],
      "TITLU_PROPRIETATE"                  => %w[INTAB]
    }.freeze

    # Combinații deed_type → title (când e specific).
    DEED_TO_TITLE = {
      "CONTRACT_VANZARE-CUMPARARE" => "CONVENTIE",
      "CVC"                        => "CONVENTIE",
      "CERTIFICAT_MOSTENITOR"      => "SUCCESIUNE",
      "TITLU PROPRIETATE"          => "reconstituire",
      "TITLU_PROPRIETATE"          => "reconstituire",
      "CONTRACT_DE_PARTAJ_1130"    => "IESIRE INDIVIZIUNE"
    }.freeze

    # title (case-insensitive) → registrationtype(s) acceptate.
    # NOTĂ: analiza Sascut corectate arată că title=reconstituire poate apărea
    # și pe PROVISIONALENTRY (înscriere provizorie pentru imobile în lucru),
    # nu doar pe INTAB. Acceptăm ambele.
    TITLE_TO_REGTYPE = {
      "reconstituire"      => %w[INTAB PROVISIONALENTRY],
      "succesiune"         => %w[INTAB],
      "conventie"          => %w[INTAB],
      "construire"         => %w[INTAB],
      "hotarare"           => %w[INTAB],
      "partaj"             => %w[INTAB],
      "iesire_indiviziune" => %w[INTAB],
      "iesire indiviziune" => %w[INTAB]
    }.freeze

    # Drepturi care DOAR persoane fizice le pot deține (viager, sufletesc, etc.)
    RIGHTS_PF_ONLY = ["UZUFRUCT VIAGER", "HABITATIE", "UZ", "UZUFRUCT"].freeze

    # Drepturi care DOAR persoane juridice le dețin (administrare publică, etc.)
    RIGHTS_PJ_ONLY = %w[ADMINISTRARE COMODAT INCHIRIERE].freeze

    # ── MATRICEA OFICIALĂ ANCPI — Foaia B (proprietate) ─────────────────────
    # Sursa: PNCCF/ANCPI „Dicționar de date — Operații în Cartea Funciară".
    # Per tip de act → mulțimile valide pentru (regtype, righttype, mod dobândire).
    # Mapping en→ro: Întabulare=INTAB, Notare=NOTATION, Înscriere provizorie=PROVISIONALENTRY,
    # Înscriere posesie=POSESION_REGISTATION.
    LB_PART_B_MATRIX = {
      "ADMINISTRATIVE_1" => {
        regtypes:   %w[PROVISIONALENTRY INTAB NOTATION POSESION_REGISTATION],
        righttypes: ["PROPRIETATE", "ADMINISTRARE", "CONCESIUNE", "FOLOSINTA CU TITLU GRATUIT"],
        titles:     %w[LEGE ADJUDECARE CONSTITUIRE RECONSTITUIRE CONSTRUIRE reconstituire]
      },
      # Sub-tipuri de act administrativ
      "TITLU PROPRIETATE" => {
        regtypes:   %w[INTAB],
        righttypes: ["PROPRIETATE"],
        titles:     %w[reconstituire RECONSTITUIRE]
      },
      "TITLU_PROPRIETATE" => {
        regtypes:   %w[INTAB],
        righttypes: ["PROPRIETATE"],
        titles:     %w[reconstituire RECONSTITUIRE]
      },
      "ACT_NORMATIV" => {
        regtypes:   %w[POSESION_REGISTATION INTAB NOTATION PROVISIONALENTRY],
        righttypes: ["PROPRIETATE", "ADMINISTRARE", "CONCESIUNE", "FOLOSINTA CU TITLU GRATUIT", "SERVITUTE", "SUPERFICIE"],
        titles:     %w[LEGE]
      },
      "LEGE" => {
        regtypes:   %w[POSESION_REGISTATION INTAB NOTATION PROVISIONALENTRY],
        righttypes: ["PROPRIETATE", "ADMINISTRARE", "CONCESIUNE", "FOLOSINTA CU TITLU GRATUIT", "SERVITUTE", "SUPERFICIE"],
        titles:     %w[LEGE]
      },
      "ACT_NOTARIAL" => {
        regtypes:   %w[INTAB NOTATION POSESION_REGISTATION PROVISIONALENTRY],
        righttypes: ["PROPRIETATE", "SERVITUTE", "SUPERFICIE"],
        titles:     ["CONVENTIE", "SUCCESIUNE", "IESIRE_INDIVIZIUNE", "IESIRE DIN INDIVIZIUNE", "partaj"]
      },
      "CERTIFICAT_MOSTENITOR" => {
        regtypes:   %w[INTAB],
        righttypes: ["PROPRIETATE"],
        titles:     ["SUCCESIUNE"]
      },
      "CONTRACT_VANZARE-CUMPARARE" => {
        regtypes:   %w[INTAB NOTATION],
        righttypes: ["PROPRIETATE", "SUPERFICIE"],
        titles:     ["CONVENTIE"]
      },
      "CVC" => {
        regtypes:   %w[INTAB],
        righttypes: ["PROPRIETATE"],
        titles:     ["CONVENTIE"]
      },
      "CONTRACT_DE_PARTAJ_1130" => {
        regtypes:   %w[INTAB],
        righttypes: ["PROPRIETATE"],
        titles:     ["IESIRE INDIVIZIUNE", "IESIRE_INDIVIZIUNE", "partaj"]
      },
      "ACTIUNE_INSTANTA" => {
        regtypes:   %w[NOTATION], righttypes: [], titles: []
      },
      "CERTIFICAT_GREFA1" => {
        regtypes:   %w[NOTATION], righttypes: [], titles: []
      },
      "HOTARARE_JUDECATOREASCA" => {
        regtypes:   %w[INTAB PROVISIONALENTRY NOTATION],
        righttypes: ["PROPRIETATE", "ADMINISTRARE", "CONCESIUNE", "FOLOSINTA CU TITLU GRATUIT", "SERVITUTE", "SUPERFICIE"],
        titles:     ["HOTARARE", "UZUCAPIUNE", "IESIRE_INDIVIZIUNE", "IESIRE DIN INDIVIZIUNE"]
      },
      "INSCRIS_SUB_SEMNATURA_PRIVATA" => {
        regtypes:   %w[NOTATION], righttypes: [], titles: []
      },
      "ORDONANTA" => {
        regtypes:   %w[NOTATION], righttypes: [], titles: []
      },
      "SOMATIE" => {
        regtypes:   %w[NOTATION], righttypes: [], titles: []
      },
      "REGISTRUL_CADASTRAL_AL_IMOBILELOR" => {
        regtypes:   %w[NOTATION], righttypes: [], titles: []
      }
    }.freeze

    # Matricea oficială ANCPI — Foaia C (sarcini / drepturi reale derivate)
    LB_PART_C_MATRIX = {
      "ADMINISTRATIVE_1" => {
        regtypes:   %w[INTAB NOTATION],
        righttypes: ["IPOTECA", "IPOTECA LEGALA"],
        titles:     %w[LEGE]
      },
      "ACT_NORMATIV" => {
        regtypes:   %w[INTAB NOTATION],
        righttypes: ["COMODAT", "CONCESIUNE", "FOLOSINTA", "FOLOSINTA SPECIALA", "INCHIRIERE",
                     "IPOTECA", "IPOTECA LEGALA", "LEASING IMOBILIAR", "SERVITUTE", "SUPERFICIE"],
        titles:     %w[LEGE]
      },
      "LEGE" => {
        regtypes:   %w[INTAB NOTATION],
        righttypes: ["COMODAT", "CONCESIUNE", "FOLOSINTA", "FOLOSINTA SPECIALA", "INCHIRIERE",
                     "IPOTECA", "IPOTECA LEGALA", "LEASING IMOBILIAR", "SERVITUTE", "SUPERFICIE"],
        titles:     %w[LEGE]
      },
      "ACT_NOTARIAL" => {
        regtypes:   %w[PROVISIONALENTRY INTAB NOTATION],
        righttypes: ["CONCESIUNE", "FOLOSINTA", "FOLOSINTA SPECIALA", "HABITATIE", "INCHIRIERE",
                     "IPOTECA", "IPOTECA LEGALA", "LEASING IMOBILIAR", "SERVITUTE",
                     "SUPERFICIE", "UZ", "UZUFRUCT", "UZUFRUCT VIAGER"],
        titles:     ["CONVENTIE", "IESIRE_INDIVIZIUNE", "IESIRE DIN INDIVIZIUNE", "SUCCESIUNE"]
      },
      "ACTIUNE_INSTANTA" => {
        regtypes:   %w[NOTATION], righttypes: [], titles: []
      },
      "CERTIFICAT_GREFA1" => {
        regtypes:   %w[NOTATION], righttypes: [], titles: []
      },
      "HOTARARE_JUDECATOREASCA" => {
        regtypes:   %w[INTAB PROVISIONALENTRY NOTATION],
        righttypes: ["COMODAT", "CONCESIUNE", "FOLOSINTA", "FOLOSINTA SPECIALA", "HABITATIE",
                     "INCHIRIERE", "IPOTECA", "IPOTECA LEGALA", "LEASING IMOBILIAR",
                     "SERVITUTE", "SUPERFICIE", "UZ", "UZUFRUCT VIAGER", "PRIVILEGIU IMOBILIAR"],
        titles:     ["HOTARARE"]
      },
      "INSCRIS_SUB_SEMNATURA_PRIVATA" => {
        regtypes:   %w[NOTATION], righttypes: [], titles: []
      },
      "ORDONANTA" => {
        regtypes:   %w[NOTATION], righttypes: [], titles: []
      },
      "SOMATIE" => {
        regtypes:   %w[NOTATION], righttypes: [], titles: []
      }
    }.freeze

    # Marker-uri CNP/CUI speciale ANCPI (per CADCF-3 din specificația oficială):
    #   0000000000000 = proprietar UNIDENTIFIED (numele e completat dar identitatea juridică nu)
    #   9999999999999 = CNP există documentar dar nu trece checksum SAU nu e cunoscut
    CNP_PLACEHOLDER_MARKERS = %w[0000000000000 9999999999999].freeze

    # Reguli care necesită un flux specific de operațiune cadastrală individuală.
    # Le sărim când OPERATIONTYPE = GENERAL_CADASTRE.
    OPERATION_SPECIFIC_RULES = %w[
      ERR4 ERR5 ERR6 ERR7 ERR8 ERR9 ERR10 ERR12 ERR14 ERR17 ERR18 ERR28
      ERR29 ERR30 ERR32 ERR34 ERR40 ERR42 ERR44 ERR50 ERR51 ERR59
    ].freeze

    AREA_TOLERANCE_INFO    = 0.02  # 2% — sub asta nu raportăm
    AREA_TOLERANCE_WARN    = 0.05  # 2-5% → ERR35 warning
    AREA_TOLERANCE_NEG_ERR = -0.05 # < -5% → ERR36 error

    attr_reader :errors

    def initialize(file_description)
      @fd     = file_description
      @errors = []
    end

    def call
      return @errors if skip_universal?

      run_rule(:err1)
      run_rule(:err2)
      run_rule(:err3)
      run_rule(:err11)
      run_rule(:err13)
      run_rule(:err15)
      run_rule(:err16)
      # ERR19/20/21 (taxvalue/legalarea construcție) — opționale conform analizei
      # comparative Sascut (apar pe 99% din date corecte). Nu mai raportăm.
      run_rule(:err22)
      run_rule(:err23)
      run_rule(:err24)
      run_rule(:err25)
      run_rule(:err26_35_36)
      run_rule(:err27)
      run_rule(:err31)
      run_rule(:err33)
      run_rule(:err37)
      run_rule(:err38)
      run_rule(:err39)
      run_rule(:err41)
      run_rule(:err43)
      run_rule(:err45)
      run_rule(:err46)
      run_rule(:err47)
      run_rule(:err48)
      run_rule(:err49)
      run_rule(:err52)
      run_rule(:err53)
      run_rule(:err54)
      # err55, err57, err60 (cadsector/postalnumber/zipcode) — completate la export
      run_rule(:err56)
      run_rule(:err58)
      run_rule(:err61)
      run_rule(:err62)

      # ── ERR100+ — corelații Registration (analiza patternurilor reale) ──
      run_rule(:err100)
      run_rule(:err101)
      run_rule(:err102)
      run_rule(:err103)
      run_rule(:err104)
      run_rule(:err105)
      run_rule(:err106)
      run_rule(:err107)
      run_rule(:err108)
      run_rule(:err109)
      run_rule(:err110)
      run_rule(:err111)
      run_rule(:err112)
      run_rule(:err113)
      run_rule(:err114)
      run_rule(:err116)
      run_rule(:err117)
      run_rule(:err118)
      run_rule(:err119)

      # ── ERR200+ — matricea oficială ANCPI (PNCCF/Foaia B + Foaia C) ──
      run_rule(:err200)
      run_rule(:err201)
      run_rule(:err202)
      run_rule(:err203)
      run_rule(:err204)

      # ── ERR300+ — reguli din legislație (Lg 7/1996, Ord 600/2023, Ord 1/2020) ──
      run_rule(:err300)
      run_rule(:err301)
      run_rule(:err302)
      run_rule(:err303)

      @errors
    end

    private

    def skip_universal? = false # extensible

    def run_rule(name)
      send(name)
    rescue => e
      Rails.logger.warn "[AncpiRules] #{name} raised: #{e.class}: #{e.message}"
    end

    # ── ERR1: ≥1 imobil în fișier ────────────────────────────────────────────
    def err1
      return if @fd.lands.exists?
      add(entity: @fd, code: "ERR1", severity: "error",
          msg: "Nu există imobile (lands) în fișier")
    end

    # ── ERR2: ≥1 persoană dacă există imobile ────────────────────────────────
    def err2
      return unless @fd.lands.exists?
      return if @fd.persons.exists?
      add(entity: @fd, code: "ERR2", severity: "error",
          msg: "Nu există date despre persoane/proprietari")
    end

    # ── ERR3: ≥1 act dacă există persoane ────────────────────────────────────
    def err3
      return unless @fd.persons.exists?
      return if @fd.deeds.exists?
      add(entity: @fd, code: "ERR3", severity: "error",
          msg: "Nu există date despre acte juridice (deeds)")
    end

    # ── ERR11: imobilul are adresa atașată ───────────────────────────────────
    def err11
      @fd.lands.where(address_id: nil).find_each do |land|
        add(entity: land, code: "ERR11", severity: "warning",
            msg: "Imobilul nu are adresă completată")
      end
    end

    # ── ERR13: imobil cu cel puțin o parcelă ─────────────────────────────────
    def err13
      @fd.lands.includes(:parcels).find_each do |land|
        next if land.parcels.any?
        add(entity: land, code: "ERR13", severity: "warning",
            msg: "Imobilul nu are nicio parcelă")
      end
    end

    # ── ERR15: suma suprafetelor parcelelor = suprafata terenului (din coords) ──
    # Datele cgxml stochează suprafata în `land.measuredarea` (din coordonate)
    # și `parcel.measuredarea`. Tolerăm rotunjire 1 mp.
    def err15
      @fd.lands.includes(:parcels).find_each do |land|
        next if land.measuredarea.to_f.zero?
        sum = land.parcels.sum(:measuredarea).to_f
        next if sum.zero? # acoperit de err13
        delta = (sum - land.measuredarea.to_f).abs
        next if delta <= 1.0
        add(entity: land, code: "ERR15", severity: "warning",
            msg: "Suma suprafetelor parcelelor (#{sum.round(2)}) != suprafata teren (#{land.measuredarea.round(2)}); diferenta #{delta.round(2)} mp")
      end
    end

    # ── ERR16: suma suprafetelor constructiilor <= suprafata terenului ──────
    def err16
      @fd.lands.includes(:buildings).find_each do |land|
        sum = land.buildings.sum(:measuredarea).to_f
        next if sum <= land.measuredarea.to_f
        add(entity: land, code: "ERR16", severity: "warning",
            msg: "Suma suprafetelor constructiilor (#{sum.round(2)}) > suprafata teren (#{land.measuredarea.round(2)})")
      end
    end

    # ── ERR19: parcel.taxvalue ──────────────────────────────────────────────
    def err19
      @fd.lands.joins(:parcels).where(parcels: { taxvalue: nil }).find_each do |land|
        add(entity: land, code: "ERR19", severity: "warning",
            msg: "Valoarea de impozitare a unei parcele lipsește")
        break # un singur warning per imobil ca să nu inundăm
      end
    end

    # ── ERR20: building.taxvalue ────────────────────────────────────────────
    def err20
      @fd.lands.joins(:buildings).where(buildings: { taxvalue: nil }).find_each do |land|
        add(entity: land, code: "ERR20", severity: "warning",
            msg: "Valoarea de impozitare a unei constructii lipsește")
        break
      end
    end

    # ── ERR21: building.legalarea (Suprafata din acte) ──────────────────────
    def err21
      @fd.lands.includes(:buildings).find_each do |land|
        land.buildings.each do |b|
          next if b.legalarea.present? && b.legalarea > 0
          add(entity: b, code: "ERR21", severity: "warning",
              msg: "Suprafata din acte a constructiei lipsește")
        end
      end
    end

    # ── ERR22: imobil intravilan ↔ cel puțin o parcelă intravilan ───────────
    def err22
      @fd.lands.includes(:address, :parcels).find_each do |land|
        next unless land.address&.intravilan
        next if land.parcels.any? { |p| p.intravilan }
        add(entity: land, code: "ERR22", severity: "warning",
            msg: "Imobil cu adresa intravilan dar nicio parcela intravilan")
      end
    end

    # ── ERR23: imobil cu construcții → trebuie intravilan ───────────────────
    def err23
      @fd.lands.includes(:address, :buildings).find_each do |land|
        next if land.buildings.empty?
        next if land.address&.intravilan
        add(entity: land, code: "ERR23", severity: "warning",
            msg: "Imobil cu constructii dar adresa nu e intravilan")
      end
    end

    # ── ERR24: suprafata constructie la sol <= parcele CC ───────────────────
    def err24
      @fd.lands.includes(:buildings, :parcels).find_each do |land|
        next if land.buildings.empty?
        cc_area = land.parcels.where(usecategory: "CC").sum(:measuredarea).to_f
        bld_area = land.buildings.sum(:measuredarea).to_f
        next if cc_area.zero? # nu avem CC declarat → diferit warning (acoperit ERR23)
        next if bld_area <= cc_area + 1.0  # toleranță 1 mp
        add(entity: land, code: "ERR24", severity: "warning",
            msg: "Suprafata construita (#{bld_area.round(2)}) > parcela CC (#{cc_area.round(2)})")
      end
    end

    # ── ERR25: land.parcellegalarea sau suma din parcele ────────────────────
    def err25
      @fd.lands.find_each do |land|
        next if land.parcellegalarea.present? && land.parcellegalarea > 0
        next if land.parcels.where("measuredarea > 0").exists?
        add(entity: land, code: "ERR25", severity: "warning",
            msg: "Total suprafata din acte teren lipsește")
      end
    end

    # ── ERR26/35/36: tolerance suprafata măsurată vs din acte ──────────────
    #   |delta/legal| ≤ 2%  → OK
    #   2% < delta ≤ 5%     → ERR35 warning
    #   delta < -5%         → ERR36 error
    #   delta > 5%          → ERR26 warning (legacy "5% absolute")
    def err26_35_36
      @fd.lands.find_each do |land|
        legal = land.parcellegalarea.to_f
        measured = land.measuredarea.to_f
        next if legal.zero? || measured.zero?
        pct = (measured - legal) / legal
        abs_pct = pct.abs
        if pct < AREA_TOLERANCE_NEG_ERR
          add(entity: land, code: "ERR36", severity: "error",
              msg: "Suprafata masurata - din acte = #{(pct*100).round(2)}% (sub -5%)")
        elsif abs_pct > AREA_TOLERANCE_WARN
          add(entity: land, code: "ERR26", severity: "warning",
              msg: "Diferenta masurata-acte = #{(pct*100).round(2)}% (peste 5%)")
        elsif abs_pct > AREA_TOLERANCE_INFO
          add(entity: land, code: "ERR35", severity: "warning",
              msg: "Diferenta masurata-acte = #{(pct*100).round(2)}% (intre 2% si 5%)")
        end
      end
    end

    # ── ERR27: building.totalarea (Total suprafata din acte construcție) ────
    def err27
      @fd.lands.includes(:buildings).find_each do |land|
        land.buildings.each do |b|
          next if b.totalarea.present? && b.totalarea > 0
          add(entity: b, code: "ERR27", severity: "warning",
              msg: "Total suprafata din acte constructie lipsește")
        end
      end
    end

    # ── ERR31: condominium → parti comune ───────────────────────────────────
    # Condominium = building cu iuno > 0 (are unități individuale).
    def err31
      @fd.lands.includes(buildings: :building_common_parts).find_each do |land|
        land.buildings.each do |b|
          next if b.iuno.to_i < 1
          next if b.building_common_parts.exists?
          add(entity: b, code: "ERR31", severity: "warning",
              msg: "Constructia condominiu nu are parti comune introduse")
        end
      end
    end

    # ── ERR33: parcele intravilan ↔ adresa intravilan ───────────────────────
    def err33
      @fd.lands.includes(:address, :parcels).find_each do |land|
        next unless land.address
        addr_intra = land.address.intravilan
        has_intra  = land.parcels.any? { |p| p.intravilan }
        has_extra  = land.parcels.any? { |p| !p.intravilan }
        if addr_intra && !has_intra
          add(entity: land, code: "ERR33", severity: "warning",
              msg: "Adresa intravilan dar nicio parcela intravilan")
        elsif !addr_intra && has_intra && !has_extra
          add(entity: land, code: "ERR33", severity: "warning",
              msg: "Adresa extravilan dar toate parcelele sunt intravilan")
        end
      end
    end

    # ── ERR37: suma cotelor parti comune = 100% pe construcție ──────────────
    # NOTĂ: schema actuală a building_common_parts nu are coloana de cotă/procent
    # — așa că verificăm doar prezența (acoperit deja ERR31). Skip strict.
    def err37
      # building_common_parts nu are field de %. Skip până se adaugă coloana.
    end

    # ── ERR38: proprietar (person) → adresa ─────────────────────────────────
    def err38
      @fd.persons.where(address_id: nil).find_each do |p|
        add(entity: p, code: "ERR38", severity: "warning",
            msg: "Persoana proprietar nu are adresa completata")
      end
    end

    # ── ERR39: parcel.usecategory ───────────────────────────────────────────
    def err39
      @fd.lands.joins(:parcels).where(parcels: { usecategory: [nil, ""] }).find_each do |land|
        add(entity: land, code: "ERR39", severity: "warning",
            msg: "Categoria de folosinta lipsește pentru o parcela")
        break
      end
    end

    # ── ERR41: building.address.siruta = land.address.siruta ────────────────
    def err41
      @fd.lands.includes(:address, buildings: :address).find_each do |land|
        next unless land.address&.siruta
        land.buildings.each do |b|
          next unless b.address
          next if b.address.siruta == land.address.siruta
          add(entity: b, code: "ERR41", severity: "warning",
              msg: "Localitatea constructiei (#{b.address.siruta}) != cea a terenului (#{land.address.siruta})")
        end
      end
    end

    # ── ERR43: persoana fără CNP/CUI ────────────────────────────────────────
    # Per CADCF-3: dacă CNP nu există, se completează cu 9999999999999.
    # Pentru proprietari neidentificați se completează cu 0000000000000.
    # ERR43 flag-uiește doar cazurile când idcode e gol (nici marker, nici real).
    def err43
      @fd.persons.where(idcode: [nil, "", "-", "_"]).find_each do |p|
        add(entity: p, code: "ERR43", severity: "warning",
            msg: "Persoana nu are CNP/CUI completat — folosește marker 0000000000000 (neidentificat) sau 9999999999999 (necunoscut)")
      end
    end

    # ── ERR45: fiecare imobil → cel puțin o înscriere ───────────────────────
    def err45
      @fd.lands.includes(:registration_x_entities).find_each do |land|
        next if land.registration_x_entities.any?
        add(entity: land, code: "ERR45", severity: "warning",
            msg: "Imobilul nu are nicio inscriere (registration) asociata")
      end
    end

    # ── ERR46: building fără acte → NU are inscrieri ────────────────────────
    # "fără acte" = islegal=false (construcție fără autorizație/acte de proprietate)
    def err46
      @fd.lands.includes(buildings: :registration_x_entities).find_each do |land|
        land.buildings.each do |b|
          next if b.islegal
          next unless b.registration_x_entities.exists?
          add(entity: b, code: "ERR46", severity: "warning",
              msg: "Constructie fara acte (islegal=false) dar are inscriere")
        end
      end
    end

    # ── ERR47: o înscriere nu poate fi atașată la teren ȘI la unitate ───────
    def err47
      @fd.deeds.includes(registrations: :registration_x_entities).find_each do |d|
        d.registrations.each do |r|
          links = r.registration_x_entities
          has_land = links.any? { |l| l.land_id.present? }
          has_iu   = links.any? { |l| l.individual_unit_id.present? }
          next unless has_land && has_iu
          add(entity: r, code: "ERR47", severity: "warning",
              msg: "Inscrierea are atasata si teren si unitate individuala")
        end
      end
    end

    # ── ERR48: condominium → ≥2 unități individuale ─────────────────────────
    def err48
      @fd.lands.includes(buildings: :individual_units).find_each do |land|
        land.buildings.each do |b|
          next if b.iuno.to_i < 2
          actual = b.individual_units.count
          next if actual >= 2
          add(entity: b, code: "ERR48", severity: "warning",
              msg: "Constructie condominiu cu doar #{actual} UI (necesar >=2)")
        end
      end
    end

    # ── ERR49: cadgenno != "0" și prezent ───────────────────────────────────
    def err49
      @fd.lands.where("cadgenno IS NULL OR cadgenno IN ('', '0')").find_each do |land|
        add(entity: land, code: "ERR49", severity: "warning",
            msg: "Identificator Cadastru General (cadgenno) lipsește sau e 0")
      end
    end

    # ── ERR52: parcel.cadgenno present ──────────────────────────────────────
    def err52
      @fd.lands.joins(:parcels).where("parcels.cadgenno IS NULL OR parcels.cadgenno = ''").find_each do |land|
        add(entity: land, code: "ERR52", severity: "warning",
            msg: "Cel putin o parcela nu are CADGENNO")
        break
      end
    end

    # ── ERR53: building.cadgenno present ────────────────────────────────────
    def err53
      @fd.lands.joins(:buildings).where("buildings.cadgenno IS NULL OR buildings.cadgenno = ''").find_each do |land|
        add(entity: land, code: "ERR53", severity: "warning",
            msg: "Cel putin o constructie nu are CADGENNO")
        break
      end
    end

    # ── ERR54: individual_unit.cadgenno present ─────────────────────────────
    def err54
      @fd.lands.joins(buildings: :individual_units)
              .where("individual_units.cadgenno IS NULL OR individual_units.cadgenno = ''")
              .find_each do |land|
        add(entity: land, code: "ERR54", severity: "warning",
            msg: "Cel putin o unitate individuala nu are CADGENNO")
        break
      end
    end

    # ── ERR55: land.cadsector present ───────────────────────────────────────
    def err55
      @fd.lands.where(cadsector: [nil, ""]).find_each do |land|
        add(entity: land, code: "ERR55", severity: "warning",
            msg: "Sector cadastral (cadsector) lipsește pentru imobil")
      end
    end

    # ── ERR56: building.levelsno >= 1 ───────────────────────────────────────
    def err56
      @fd.lands.includes(:buildings).find_each do |land|
        land.buildings.each do |b|
          next if b.levelsno.to_i >= 1
          add(entity: b, code: "ERR56", severity: "warning",
              msg: "Constructia nu are numar de niveluri (levelsno) completat")
        end
      end
    end

    # ── ERR57: address.postalnumber present ─────────────────────────────────
    def err57
      @fd.lands.includes(:address).find_each do |land|
        next unless land.address
        next if land.address.postalnumber.present?
        add(entity: land.address, code: "ERR57", severity: "warning",
            msg: "Numarul postal lipsește din adresa imobilului")
      end
    end

    # ── ERR58: suma cotelor înscrierilor = 1/1 ──────────────────────────────
    # Parsăm `quotatype` și `actualquota` (string "1/2", "0.5", "50") per imobil.
    # Algoritm: pe fiecare land, însumăm cotele inscrierilor PROPRIETATE; trebuie ≈ 1.
    def err58
      @fd.lands.includes(registrations: :deed).find_each do |land|
        proprietate_regs = land.registrations.where(righttype: "PROPRIETATE")
        next if proprietate_regs.empty?
        sum = proprietate_regs.sum { |r| quota_to_f(r) }
        next if (sum - 1.0).abs < 0.01
        add(entity: land, code: "ERR58", severity: "warning",
            msg: "Suma cotelor de proprietate (#{sum.round(3)}) != 1/1")
      end
    end

    # ── ERR60: address.zipcode present ──────────────────────────────────────
    def err60
      # zipcode lipsește în majoritatea datelor de cadastru general — păstrăm
      # severitate joasă (info-level via warning, dar 1 per FD ca să nu inundăm).
      land = @fd.lands.joins(:address).where(addresses: { zipcode: [nil, ""] }).first
      return unless land
      add(entity: land, code: "ERR60", severity: "warning",
          msg: "Adresa imobilului nu are cod postal (zipcode)")
    end

    # ── ERR61: PJ → lastname ────────────────────────────────────────────────
    def err61
      @fd.persons.where(isphysical: false).where(lastname: [nil, "", "-", "_"]).find_each do |p|
        add(entity: p, code: "ERR61", severity: "warning",
            msg: "Persoana juridica nu are denumirea (lastname) completata")
      end
    end

    # ── ERR62: PF → firstname + lastname ────────────────────────────────────
    def err62
      @fd.persons.where(isphysical: true).find_each do |p|
        if blank_or_placeholder?(p.firstname) || blank_or_placeholder?(p.lastname)
          add(entity: p, code: "ERR62", severity: "warning",
              msg: "Persoana fizica fara firstname/lastname completate")
        end
      end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # ERR100+ — REGULI DE CORELAȚIE REGISTRATION (descoperite empiric)
    # ─────────────────────────────────────────────────────────────────────────

    # Helper: iterează prin toate registration-urile fișierului.
    def registrations
      @fd.deeds.includes(:registrations).flat_map { |d| d.registrations.to_a.map { |r| [d, r] } }
    end

    # ── ERR100: INTAB + PROPRIETATE → cel puțin o persoană atașată ─────────
    def err100
      registrations.each do |_d, r|
        next unless r.registrationtype == "INTAB" && r.righttype == "PROPRIETATE"
        next if Person.where(registration_id: r.id).exists?
        add(entity: r, code: "ERR100", severity: "error",
            msg: "Inscriere INTAB+PROPRIETATE fara persoana atasata (proprietar lipsa)")
      end
    end

    # ── ERR101: INTAB + PROPRIETATE → quotatype prezent (cotă FRACTION_QUOTA tipic) ──
    def err101
      registrations.each do |_d, r|
        next unless r.registrationtype == "INTAB" && r.righttype == "PROPRIETATE"
        next if r.quotatype.present? && r.actualquota.present? && !%w[- _].include?(r.actualquota.to_s.strip)
        add(entity: r, code: "ERR101", severity: "error",
            msg: "Inscriere INTAB+PROPRIETATE fara cota completata (quotatype + actualquota)")
      end
    end

    # ── ERR102: NOTATION cu righttype completat → anomalie (rare) ──────────
    def err102
      registrations.each do |_d, r|
        next unless r.registrationtype == "NOTATION"
        next if r.righttype.blank? || %w[- _].include?(r.righttype.to_s.strip)
        add(entity: r, code: "ERR102", severity: "warning",
            msg: "Inscriere NOTATION cu righttype=#{r.righttype} (NOTATION nu poartă drepturi reale)")
      end
    end

    # ── ERR103: INTAB + IPOTECA(_LEGALA) → valueamount + valuecurrency ──────
    def err103
      registrations.each do |_d, r|
        next unless r.registrationtype == "INTAB"
        next unless r.righttype.in?(["IPOTECA", "IPOTECA LEGALA"])
        if r.valueamount.blank? || %w[- _].include?(r.valueamount.to_s.strip)
          add(entity: r, code: "ERR103", severity: "warning",
              msg: "Ipoteca fara valoare (valueamount) — recomandat completat")
        end
      end
    end

    # ── ERR104: deedtype = TITLU PROPRIETATE → registrationtype = INTAB ────
    def err104
      registrations.each do |d, r|
        next unless ["TITLU PROPRIETATE", "TITLU_PROPRIETATE"].include?(d.deedtype.to_s)
        next if r.registrationtype == "INTAB"
        add(entity: r, code: "ERR104", severity: "error",
            msg: "Titlu de proprietate trebuie sa genereze INTAB (gasit: #{r.registrationtype})")
      end
    end

    # ── ERR105: deedtype = TITLU PROPRIETATE → title = reconstituire ───────
    def err105
      registrations.each do |d, r|
        next unless ["TITLU PROPRIETATE", "TITLU_PROPRIETATE"].include?(d.deedtype.to_s)
        next if r.title.to_s.downcase.strip == "reconstituire"
        add(entity: r, code: "ERR105", severity: "error",
            msg: "Titlu de proprietate trebuie sa aiba title=reconstituire (gasit: #{r.title.inspect})")
      end
    end

    # ── ERR106: deedtype = REGISTRUL_CADASTRAL_AL_IMOBILELOR → NOTATION ────
    def err106
      registrations.each do |d, r|
        next unless d.deedtype == "REGISTRUL_CADASTRAL_AL_IMOBILELOR"
        next if r.registrationtype == "NOTATION"
        add(entity: r, code: "ERR106", severity: "error",
            msg: "Registru cadastral al imobilelor genereaza doar NOTATION (gasit: #{r.registrationtype})")
      end
    end

    # ── ERR107: INSCRIS_SUB_SEMNATURA_PRIVATA → NOTATION ───────────────────
    def err107
      registrations.each do |d, r|
        next unless d.deedtype == "INSCRIS_SUB_SEMNATURA_PRIVATA"
        next if r.registrationtype == "NOTATION"
        add(entity: r, code: "ERR107", severity: "warning",
            msg: "Inscris sub semnatura privata genereaza tipic NOTATION (gasit: #{r.registrationtype})")
      end
    end

    # ── ERR108: SOMATIE → NOTATION ─────────────────────────────────────────
    def err108
      registrations.each do |d, r|
        next unless d.deedtype == "SOMATIE"
        next if r.registrationtype == "NOTATION"
        add(entity: r, code: "ERR108", severity: "error",
            msg: "Somatia se inscrie ca NOTATION (gasit: #{r.registrationtype})")
      end
    end

    # ── ERR109: CONTRACT_VANZARE-CUMPARARE / CVC → title = CONVENTIE ───────
    def err109
      registrations.each do |d, r|
        next unless %w[CONTRACT_VANZARE-CUMPARARE CVC].include?(d.deedtype)
        next if r.registrationtype != "INTAB" # doar pentru INTAB
        next if r.title.to_s.upcase.strip == "CONVENTIE"
        add(entity: r, code: "ERR109", severity: "warning",
            msg: "Contract vanzare-cumparare INTAB trebuie sa aiba title=CONVENTIE (gasit: #{r.title.inspect})")
      end
    end

    # ── ERR110: CERTIFICAT_MOSTENITOR → title = SUCCESIUNE ─────────────────
    def err110
      registrations.each do |d, r|
        next unless d.deedtype == "CERTIFICAT_MOSTENITOR"
        next if r.title.to_s.upcase.strip == "SUCCESIUNE"
        add(entity: r, code: "ERR110", severity: "warning",
            msg: "Certificat de mostenitor trebuie sa aiba title=SUCCESIUNE (gasit: #{r.title.inspect})")
      end
    end

    # ── ERR111-113: title → registrationtype obligatoriu ────────────────────
    def title_to_regtype_check(rule_code, severity = "warning")
      registrations.each do |_d, r|
        title_norm = r.title.to_s.downcase.strip
        expected = TITLE_TO_REGTYPE[title_norm] # array de tipuri acceptate
        next unless expected
        next if expected.include?(r.registrationtype)
        next if rule_code == "ERR111" && title_norm != "reconstituire"
        next if rule_code == "ERR112" && title_norm != "succesiune"
        next if rule_code == "ERR113" && title_norm != "conventie"
        add(entity: r, code: rule_code, severity: severity,
            msg: "title=#{r.title.inspect} ar trebui sa fie inscriere #{expected.join(' sau ')} (gasit: #{r.registrationtype})")
      end
    end

    def err111 = title_to_regtype_check("ERR111", "error")
    def err112 = title_to_regtype_check("ERR112", "warning")
    def err113 = title_to_regtype_check("ERR113", "warning")

    # ── ERR114: Registration → atașată la cel puțin o entitate ─────────────
    def err114
      registrations.each do |_d, r|
        next if RegistrationXEntity.where(registration_id: r.id).exists?
        add(entity: r, code: "ERR114", severity: "error",
            msg: "Inscrierea nu e atasata la nicio entitate (land/building/IU)")
      end
    end

    # ── ERR116: drepturi viager → doar persoane fizice ─────────────────────
    def err116
      registrations.each do |_d, r|
        next unless RIGHTS_PF_ONLY.include?(r.righttype.to_s.strip)
        # Verificăm că nu există PJ atașat la această înscriere
        if Person.where(registration_id: r.id, isphysical: false).exists?
          add(entity: r, code: "ERR116", severity: "error",
              msg: "Drept #{r.righttype} (viager/personal) atribuit unei persoane juridice — invalid")
        end
      end
    end

    # ── ERR117: drepturi instituționale → tipic persoane juridice ──────────
    def err117
      registrations.each do |_d, r|
        next unless RIGHTS_PJ_ONLY.include?(r.righttype.to_s.strip)
        if Person.where(registration_id: r.id, isphysical: true).exists?
          add(entity: r, code: "ERR117", severity: "warning",
              msg: "Drept #{r.righttype} atribuit unei persoane fizice — tipic e pentru PJ")
        end
      end
    end

    # ── ERR118: appdate (data cererii) anterior datei actului ──────────────
    def err118
      registrations.each do |d, r|
        next if r.appdate.nil? || d.deeddate.nil?
        next if r.appdate >= d.deeddate
        add(entity: r, code: "ERR118", severity: "warning",
            msg: "Data cererii inscrierii (#{r.appdate.to_date}) anterioara datei actului (#{d.deeddate.to_date})")
      end
    end

    # ── ERR119: NOTATION + PROPRIETATE → anomalie (PROPRIETATE necesită INTAB) ──
    def err119
      registrations.each do |_d, r|
        next unless r.registrationtype == "NOTATION" && r.righttype == "PROPRIETATE"
        add(entity: r, code: "ERR119", severity: "error",
            msg: "Dreptul de proprietate trebuie inscris ca INTAB, nu NOTATION")
      end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # ERR200+ — MATRICEA OFICIALĂ ANCPI (PNCCF „Dicționar de date")
    # ─────────────────────────────────────────────────────────────────────────

    # Helper — alege matricea aplicabilă (B sau C) după lbpartno.
    def lb_matrix_for(reg)
      case reg.lbpartno
      when 2 then LB_PART_B_MATRIX
      when 3 then LB_PART_C_MATRIX
      else nil
      end
    end

    # ── ERR200: lbpartno absent ─────────────────────────────────────────────
    # Conform CFSTR-7, LandBookPart e Yes pentru sporadic records.
    def err200
      registrations.each do |_d, r|
        next if r.lbpartno.present? && [2, 3].include?(r.lbpartno)
        add(entity: r, code: "ERR200", severity: "warning",
            msg: "Inscrierea nu are Foaia CF completata (lbpartno 2=B / 3=C)")
      end
    end

    # ── ERR201: combinația deedtype + registrationtype NU e în matricea ANCPI ──
    def err201
      registrations.each do |d, r|
        mat = lb_matrix_for(r)
        next unless mat # fără lbpartno cunoscut → ERR200 deja
        rules = mat[d.deedtype]
        next unless rules # tip de act nemapat în matrice → skip (toleranță pentru data drift)
        next if rules[:regtypes].include?(r.registrationtype)
        foaia = r.lbpartno == 2 ? "B (proprietate)" : "C (sarcini)"
        add(entity: r, code: "ERR201", severity: "error",
            msg: "Act #{d.deedtype} + Inscriere #{r.registrationtype} INVALID pe Foaia #{foaia}. " \
                 "Permise: #{rules[:regtypes].join(', ')}")
      end
    end

    # ── ERR202: righttype NU e permis pentru (deedtype, lbpartno) ───────────
    def err202
      registrations.each do |d, r|
        next if r.righttype.blank? || %w[- _].include?(r.righttype.to_s.strip)
        mat = lb_matrix_for(r)
        next unless mat
        rules = mat[d.deedtype]
        next unless rules
        next if rules[:righttypes].empty? # Notare-only deeds — fără righttype așteptat
        next if rules[:righttypes].include?(r.righttype.to_s.strip.upcase) ||
                rules[:righttypes].any? { |rt| rt.casecmp?(r.righttype.to_s.strip) }
        foaia = r.lbpartno == 2 ? "B" : "C"
        add(entity: r, code: "ERR202", severity: "error",
            msg: "Dreptul #{r.righttype} nu e permis pentru Act #{d.deedtype} pe Foaia #{foaia}. " \
                 "Permise: #{rules[:righttypes].join(', ')}")
      end
    end

    # ── ERR203: title (Mod dobândire) NU e permis pentru (deedtype, lbpartno) ──
    def err203
      registrations.each do |d, r|
        next if r.title.blank? || %w[- _].include?(r.title.to_s.strip)
        mat = lb_matrix_for(r)
        next unless mat
        rules = mat[d.deedtype]
        next unless rules
        next if rules[:titles].empty?
        next if rules[:titles].any? { |t| t.casecmp?(r.title.to_s.strip) }
        foaia = r.lbpartno == 2 ? "B" : "C"
        add(entity: r, code: "ERR203", severity: "warning",
            msg: "Mod dobandire '#{r.title}' nu e in matricea oficiala pentru Act #{d.deedtype} pe Foaia #{foaia}. " \
                 "Permise: #{rules[:titles].join(', ')}")
      end
    end

    # ── ERR204: lbpartno=2 (Foaia B) + righttype tip-C → conflict foaie ─────
    # Drepturile de sarcină (Ipoteca, Uzufruct, etc.) merg pe Foaia C, NU pe B.
    LB_C_ONLY_RIGHTS = ["IPOTECA", "IPOTECA LEGALA", "PRIVILEGIU IMOBILIAR",
                       "COMODAT", "INCHIRIERE", "LEASING IMOBILIAR",
                       "HABITATIE", "UZ", "UZUFRUCT", "UZUFRUCT VIAGER",
                       "FOLOSINTA", "FOLOSINTA SPECIALA"].freeze

    def err204
      registrations.each do |_d, r|
        next unless r.lbpartno == 2
        next unless r.righttype.present?
        next unless LB_C_ONLY_RIGHTS.include?(r.righttype.to_s.strip.upcase)
        add(entity: r, code: "ERR204", severity: "error",
            msg: "Dreptul #{r.righttype} trebuie inscris pe Foaia C (sarcini), nu pe Foaia B")
      end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # ERR300+ — REGULI DIN LEGISLAȚIE (Lg 7/1996, Ord ANCPI 600/2023, 1/2020)
    # ─────────────────────────────────────────────────────────────────────────

    # ── ERR300: construcția nu are cadgenno asignat ─────────────────────────
    # Regulile CADNUM-3/4 (format `<land>-C<n>` / `-U<m>`) sunt CONSULTATIVE —
    # PDF-ul din care provin e mai vechi. Ord 600/2023 (în vigoare) nu impune
    # formatul exact, doar prezența. Marcăm ca warning doar lipsa, nu format.
    def err300
      @fd.lands.includes(:buildings).find_each do |land|
        land.buildings.each do |b|
          actual = b.cadgenno.to_s.strip
          next unless actual.blank? || actual == "0"
          add(entity: b, code: "ERR300", severity: "warning",
              msg: "Construcția nu are cadgenno asignat (prestatorul completează la sistematic)")
        end
      end
    end

    # ── ERR301: unitatea individuală fără cadgenno asignat ──────────────────
    def err301
      @fd.lands.includes(buildings: :individual_units).find_each do |land|
        land.buildings.each do |b|
          b.individual_units.each do |iu|
            actual = iu.cadgenno.to_s.strip
            next unless actual.blank? || actual == "0"
            add(entity: iu, code: "ERR301", severity: "warning",
                msg: "Unitatea individuală nu are cadgenno asignat")
          end
        end
      end
    end

    # ── ERR302: lands cu usecategory DR sau CF (linear) pot avea cadgenno repetat ──
    # (Ord 600/2023 - imobile liniare primesc un singur nr cadastral pe UAT
    # sau pe tronsoane). Verificăm că lands cu parcele exclusiv DR sau CF
    # respectă conveția. Marcat informational.
    def err302
      @fd.lands.includes(:parcels).find_each do |land|
        next unless land.parcels.any?
        cats = land.parcels.pluck(:usecategory).compact.map(&:strip)
        next unless cats.any?
        if cats.all? { |c| c == "DR" || c == "CF" }
          # imobil liniar - validare informational doar dacă nu are cadgenno
          if land.cadgenno.blank?
            add(entity: land, code: "ERR302", severity: "warning",
                msg: "Imobil liniar (DR/CF) fără cadgenno — pe UAT-uri lungi se permite numerotare pe tronsoane")
          end
        end
      end
    end

    # ── ERR303: cadgenno unicitate la nivel UAT (Lg 7/1996 art. 2) ──────────
    # Verificăm doar în cadrul aceluiași fișier (file_description). Unicitatea
    # globală per UAT necesită cross-FD lookup, deferred în iterația următoare.
    def err303
      seen = {}
      @fd.lands.find_each do |land|
        next if land.cadgenno.blank? || land.cadgenno == "0"
        if seen[land.cadgenno]
          add(entity: land, code: "ERR303", severity: "error",
              msg: "Cadgenno '#{land.cadgenno}' duplicat — apare și la imobilul L#{seen[land.cadgenno]}")
        else
          seen[land.cadgenno] = land.id
        end
      end
    end

    # ── helpers ──────────────────────────────────────────────────────────────

    def blank_or_placeholder?(v)
      v.blank? || %w[- _].include?(v.to_s.strip)
    end

    # Parse cota din string "1/2" / "0.5" / "50%" / "100" la float în [0..1].
    def quota_to_f(reg)
      raw = (reg.actualquota.presence || reg.initialquota.presence || "1/1").to_s.strip
      case reg.quotatype.to_s
      when "FRACTION_QUOTA"
        if (m = raw.match(%r{\A(\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)\z}))
          num, den = m[1].to_f, m[2].to_f
          den.zero? ? 0.0 : num / den
        else
          raw.to_f
        end
      when "PERCENTAGE_QUOTA"
        raw.to_f / 100.0
      when "ABSOLUTE_QUOTA"
        # Cotă absolută (mp) — nu o putem aduna în 1.0 fără context; întoarcem 1.0
        # ca să nu declanșeze ERR58 (regula nu se aplică pe cote absolute).
        1.0
      else
        # Default: încearcă fracție, apoi float
        if (m = raw.match(%r{\A(\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)\z}))
          den = m[2].to_f
          den.zero? ? 0.0 : m[1].to_f / den
        else
          raw.to_f
        end
      end
    end

    def add(entity:, code:, severity:, msg:)
      @errors << {
        file_description_id: @fd.id,
        entity_type:         entity.class.name,
        entity_id:           entity.respond_to?(:id) ? entity.id : nil,
        field_name:          nil,
        error_code:          code,
        severity:            severity,
        error_message:       msg,
        current_value:       nil,
        expected_format:     nil,
        xpath:               nil
      }
    end
  end
end
