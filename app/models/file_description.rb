class FileDescription < ApplicationRecord
  has_many :lands,                   dependent: :nullify
  has_many :deeds,                   dependent: :destroy
  has_many :persons,                 dependent: :nullify
  has_many :cgxml_validation_errors, dependent: :destroy

  IMPORT_STATUSES     = %w[done partial failed].freeze
  VALIDATION_STATUSES = %w[pending in_progress valid errors].freeze

  validates :filename,          presence: true, length: { maximum: 50 }
  validates :content_hash,      uniqueness: true, allow_nil: true
  validates :import_status,     inclusion: { in: IMPORT_STATUSES }
  validates :validation_status, inclusion: { in: VALIDATION_STATUSES }

  scope :with_errors,    -> { where(validation_status: "errors") }
  scope :pending_validation, -> { where(validation_status: "pending") }

  def validation_pending? = validation_status == "pending"
  def validation_ok?      = validation_status == "valid"
  def validation_errors?  = validation_status == "errors"

  def total_entities_count
    lands.count + deeds.count + persons.count
  end
end
