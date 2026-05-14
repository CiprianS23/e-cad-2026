module Cgxml
  # Validator complet pentru CNP (persoană fizică) și CUI (persoană juridică)
  # conform algoritmilor oficiali ANAF + reguli ANCPI (marker-uri speciale).
  #
  # Folosit din CgxmlValidationService pentru validate_persons și din ERR43.
  # API:
  #   CnpValidator.classify(person.idcode)
  #     → :empty | :placeholder_unidentified | :placeholder_unknown
  #     → :valid_cnp | :invalid_cnp_checksum | :invalid_cnp_date
  #     → :invalid_cnp_county | :invalid_cnp_format | :wrong_length
  #     → :valid_cui  | :invalid_cui_checksum | :invalid_cui_format
  module CnpValidator
    extend self

    CNP_WEIGHTS = [2, 7, 9, 1, 4, 6, 3, 5, 8, 2, 7, 9].freeze
    CUI_WEIGHTS = [7, 5, 3, 2, 1, 7, 5, 3, 2].freeze

    # Marker-uri ANCPI conform CADCF-3
    PLACEHOLDER_UNIDENTIFIED = "0000000000000".freeze
    PLACEHOLDER_UNKNOWN      = "9999999999999".freeze

    # Cod județ valid (01..52 conform sistemului CNP). 47-51 sunt București sector 1..5,
    # 52 e Călărași (codul vechi). Lista oficială.
    VALID_COUNTY_CODES = (1..52).to_a.freeze

    # Clasifică un cod idcode. Returnează un symbol descriptiv.
    def classify(idcode, is_physical: nil)
      v = idcode.to_s.strip
      return :empty if v.empty? || %w[- _].include?(v)
      return :placeholder_unidentified if v == PLACEHOLDER_UNIDENTIFIED
      return :placeholder_unknown      if v == PLACEHOLDER_UNKNOWN

      # Heuristic: dacă is_physical specificat → folosim direct
      if is_physical.nil?
        # CNP = exact 13 cifre. CUI = 2-10 cifre, opțional prefix RO.
        return classify_cui(v) if v.match?(/\A(RO)?\d{2,10}\z/i)
        return classify_cnp(v)  if v.match?(/\A\d{13}\z/)
        return :invalid_format
      end

      is_physical ? classify_cnp(v) : classify_cui(v)
    end

    # Returnează un mesaj user-friendly pentru un cod de clasificare.
    def message_for(classification)
      case classification
      when :valid_cnp, :valid_cui                 then nil
      when :placeholder_unidentified              then nil # convenție valid ANCPI
      when :placeholder_unknown                   then nil # convenție valid ANCPI
      when :empty                                 then "CNP/CUI necompletat"
      when :wrong_length                          then "CNP-ul trebuie să aibă exact 13 cifre"
      when :invalid_format                        then "CNP/CUI conține caractere neacceptate"
      when :invalid_cnp_checksum                  then "CNP-ul nu trece verificarea cifrei de control"
      when :invalid_cnp_date                      then "Data nașterii din CNP e invalidă (LL-ZZ)"
      when :invalid_cnp_county                    then "Codul județ din CNP (pozițiile 8-9) e invalid"
      when :invalid_cnp_sex_century               then "Cifra de sex/secol din CNP (poziția 1) e invalidă"
      when :invalid_cui_checksum                  then "CUI-ul nu trece verificarea cifrei de control"
      else                                             "CNP/CUI invalid (cod: #{classification})"
      end
    end

    # Severitate recomandată per clasificare.
    def severity_for(classification)
      case classification
      when :valid_cnp, :valid_cui,
           :placeholder_unidentified, :placeholder_unknown
        nil # nu raportăm
      when :invalid_cnp_checksum, :invalid_cui_checksum
        "warning" # eroare în CNP-ul oficial — semnal pentru operator dar nu blocant
      else
        "error"   # format/cifră de sex/dată — clar bug în date
      end
    end

    private

    def classify_cnp(v)
      return :wrong_length unless v.length == 13
      return :invalid_format unless v.match?(/\A\d{13}\z/)
      digits = v.chars.map(&:to_i)

      # Poziția 1: S — sex + secol. 1-9 valid; 0 invalid.
      return :invalid_cnp_sex_century if digits[0].zero?

      # Poziții 2-7: AA-LL-ZZ → data nașterii
      year_2digit = digits[1] * 10 + digits[2]
      century = case digits[0]
                when 1, 2 then 1900
                when 3, 4 then 1800
                when 5, 6 then 2000
                when 7, 8, 9 then 1900  # rezidenți temporari (heuristic)
                end
      year = century + year_2digit
      month = digits[3] * 10 + digits[4]
      day   = digits[5] * 10 + digits[6]
      begin
        Date.new(year, month, day)
      rescue ArgumentError
        return :invalid_cnp_date
      end

      # Poziții 8-9: JJ — cod județ
      county = digits[7] * 10 + digits[8]
      return :invalid_cnp_county unless VALID_COUNTY_CODES.include?(county)

      # Poziții 10-12: NNN — sequence (orice 001-999; 000 invalid)
      seq = digits[9] * 100 + digits[10] * 10 + digits[11]
      return :invalid_cnp_format if seq.zero?

      # Poziția 13: C — cifră control
      sum = digits[0..11].zip(CNP_WEIGHTS).sum { |d, w| d * w }
      control = sum % 11
      control = 1 if control == 10
      return :invalid_cnp_checksum if digits[12] != control

      :valid_cnp
    end

    def classify_cui(v)
      v = v.sub(/\ARO/i, "")
      return :invalid_format unless v.match?(/\A\d{2,10}\z/)
      digits = v.chars.map(&:to_i)
      check  = digits.last
      body   = digits[0..-2]

      # Algoritm CUI ANAF: aplicare ponderi de la dreapta-stânga, padding zero la stânga.
      # Ponderile vin în ordinea aplicării pe body (cea mai din dreapta cifră × 7, etc.)
      padded_weights = CUI_WEIGHTS.first(body.length).reverse
      sum = body.zip(padded_weights).sum { |d, w| d * w }
      control = (sum * 10) % 11
      control = 0 if control == 10

      return :invalid_cui_checksum if check != control
      :valid_cui
    end
  end
end
