class CgxmlValidationErrorsController < ApplicationController
  before_action :set_error, only: [ :fix, :unfix ]

  # POST /cgxml_validation_errors/validate_field  (JSON — real-time validation)
  def validate_field
    result = validate_single_field(
      params[:entity_type],
      params[:field_name],
      params[:value]
    )
    render json: result
  end

  # PATCH /cgxml_validation_errors/:id/fix
  def fix
    record = @validation_error.entity_record
    field  = @validation_error.field_name

    if record && field
      value = coerce_value(record, field, params[:corrected_value])
      if record.update(field => value)
        @validation_error.fix!(by: params[:fixed_by].presence || "prestator")
        recalculate_counts(@validation_error.file_description)
        render json: { success: true, message: "Câmpul a fost corectat." }
      else
        render json: { success: false, errors: record.errors.full_messages }, status: :unprocessable_entity
      end
    else
      @validation_error.fix!(by: "manual")
      recalculate_counts(@validation_error.file_description)
      render json: { success: true, message: "Eroarea a fost marcată ca rezolvată." }
    end
  end

  # PATCH /cgxml_validation_errors/:id/unfix
  def unfix
    @validation_error.update!(fixed_at: nil, fixed_by: nil)
    recalculate_counts(@validation_error.file_description)
    render json: { success: true }
  end

  private

  def set_error
    @validation_error = CgxmlValidationError.find(params[:id])
  end

  def recalculate_counts(fd)
    return unless fd

    errs  = fd.cgxml_validation_errors.unfixed.errors_only.count
    warns = fd.cgxml_validation_errors.unfixed.warnings_only.count
    status = (errs + warns).zero? ? "valid" : "errors"
    fd.update_columns(
      validation_errors_count:   errs,
      validation_warnings_count: warns,
      validation_status:         status
    )
  end

  def coerce_value(record, field, raw)
    col = record.class.column_for_attribute(field.to_s)
    return raw if col.nil?

    case col.type
    when :integer then raw.to_i
    when :float   then raw.to_f
    when :boolean then ActiveRecord::Type::Boolean.new.cast(raw)
    when :datetime, :date then Time.zone.parse(raw) rescue nil
    else raw.presence
    end
  end

  def validate_single_field(entity_type, field_name, value)
    rules = field_rules_for(entity_type, field_name)
    errors = []

    rules.each do |rule|
      result = rule.call(value)
      errors << result[:message] if result[:invalid]
    end

    { valid: errors.empty?, errors: errors }
  rescue
    { valid: true, errors: [] }
  end

  # Lightweight inline rules for real-time validation (subset of CgxmlValidationService)
  def field_rules_for(entity_type, field_name)
    key = "#{entity_type}##{field_name}"
    FIELD_RULES[key] || []
  end

  SIRUTA_RULE = ->(v) {
    return { invalid: false } if v.blank?
    { invalid: !v.match?(/\A\d{1,6}\z/), message: "SIRUTA trebuie să fie numeric, max 6 cifre" }
  }

  CNP_RULE = ->(v) {
    return { invalid: false } if v.blank?
    unless v.match?(/\A\d{13}\z/)
      return { invalid: true, message: "CNP-ul trebuie să aibă exact 13 cifre numerice" }
    end
    weights = [ 2, 7, 9, 1, 4, 6, 3, 5, 8, 2, 7, 9 ]
    digits  = v.chars.map(&:to_i)
    sum     = digits[0..11].zip(weights).sum { |d, w| d * w }
    check   = (c = sum % 11) == 10 ? 1 : c
    { invalid: digits[12] != check, message: "Cifra de control a CNP-ului nu este validă" }
  }

  EMAIL_RULE = ->(v) {
    return { invalid: false } if v.blank?
    { invalid: !v.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/), message: "Format email invalid" }
  }

  NON_NEGATIVE_RULE = ->(v) {
    return { invalid: false } if v.blank?
    { invalid: v.to_f < 0, message: "Valoarea nu poate fi negativă" }
  }

  # USECATEGORY (și celelalte câmpuri-dicționar din CGXML) sunt declarate
  # `xs:string` în XSD — nu există enum oficial. Nu mai blocăm valori la edit.

  FIELD_RULES = {
    "Address#siruta"              => [ SIRUTA_RULE ],
    "Address#sirsup"              => [ SIRUTA_RULE ],
    "Person#idcode"               => [ CNP_RULE ],
    "Person#email"                => [ EMAIL_RULE ],
    "Land#measuredarea"           => [ NON_NEGATIVE_RULE ],
    "Building#measuredarea"       => [ NON_NEGATIVE_RULE ],
    "Building#totalarea"          => [ NON_NEGATIVE_RULE ],
    "IndividualUnit#measuredarea" => [ NON_NEGATIVE_RULE ],
    "Parcel#measuredarea"         => [ NON_NEGATIVE_RULE ]
  }.freeze
end
