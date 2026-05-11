class GisUserLayerGroup < ApplicationRecord
  # Grup configurabil de layere pentru Layer Manager. Vezi migrația
  # 20260511220001 pentru context.
  has_many :gis_user_layer_prefs,
           class_name: "GisUserLayerPref",
           foreign_key: :group_id,
           dependent: :nullify

  validates :owner_token, presence: true
  validates :name,        presence: true, length: { maximum: 100 }
  validates :position,    numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :for_owner, ->(token) { where(owner_token: token) }
  scope :ordered,   -> { order(:position, :id) }

  def to_h
    {
      id:        id,
      name:      name,
      position:  position,
      collapsed: !!collapsed
    }
  end
end
