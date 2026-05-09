class CgxmlValidationError < ApplicationRecord
  belongs_to :file_description

  SEVERITIES  = %w[error warning].freeze
  ERROR_CODES = %w[
    MISSING_REQUIRED
    INVALID_FORMAT
    INVALID_ENUM
    INVALID_RANGE
    BROKEN_REFERENCE
    XSD_VIOLATION
    BUSINESS_RULE
  ].freeze

  validates :entity_type,   presence: true
  validates :error_code,    inclusion: { in: ERROR_CODES }
  validates :severity,      inclusion: { in: SEVERITIES }
  validates :error_message, presence: true

  scope :errors_only,   -> { where(severity: "error") }
  scope :warnings_only, -> { where(severity: "warning") }
  scope :unfixed,       -> { where(fixed_at: nil) }
  scope :fixed,         -> { where.not(fixed_at: nil) }
  scope :by_entity,     -> { order(:entity_type, :entity_id) }

  def fixed?
    fixed_at.present?
  end

  def fix!(by: nil)
    update!(fixed_at: Time.current, fixed_by: by)
  end

  def entity_record
    entity_type.constantize.find_by(id: entity_id)
  rescue NameError
    nil
  end

  def entity_label
    case entity_type
    when "FileDescription" then "Fișier"
    when "Address"         then "Adresă"
    when "Land"            then "Teren"
    when "Building"        then "Construcție"
    when "Parcel"          then "Parcelă"
    when "IndividualUnit"  then "Unitate individuală"
    when "Deed"            then "Act"
    when "Registration"    then "Înscriere"
    when "Person"          then "Persoană"
    when "Point"           then "Punct"
    else entity_type
    end
  end

  def error_code_label
    case error_code
    when "MISSING_REQUIRED" then "Câmp obligatoriu lipsă"
    when "INVALID_FORMAT"   then "Format invalid"
    when "INVALID_ENUM"     then "Valoare nepermisă"
    when "INVALID_RANGE"    then "Valoare în afara intervalului"
    when "BROKEN_REFERENCE" then "Referință invalidă"
    when "XSD_VIOLATION"    then "Încalcă schema XSD"
    when "BUSINESS_RULE"    then "Regulă de afaceri"
    else error_code
    end
  end
end
