class GisUserLayerPref < ApplicationRecord
  # Preferință de afișare per utilizator/sesiune și per cheie layer.
  # `owner_token` = identificator stabil din cookie semnat (placeholder pentru
  # `user_id` la integrarea în aplicația e-CAD principală cu sistem de auth).

  # Definiția layer-elor cunoscute + valori implicite (sursa de adevăr server-side).
  # Spec §4.1 din `1_modul_gis.md` adaptat la layer-ele existente în aplicație.
  DEFAULTS = {
    "uat" => {
      display_name: "Limite UAT", category: "boundaries",
      visible: true, locked: true, opacity: 1.0,
      stroke_color: "#8b5cf6", fill_color: "transparent",
      stroke_width: 2.0, stroke_dash: "dashed", z_index: 100
    },
    "cgxml" => {
      display_name: "Imobile CGXML (CF existente)", category: "referinta",
      visible: true, locked: true, opacity: 0.85,
      stroke_color: "#eab308", fill_color: "rgba(254, 240, 138, 0.35)",
      stroke_width: 1.5, stroke_dash: "solid", z_index: 150
    },
    "parcele" => {
      display_name: "Parcele cadastrale (LIMITE_IMOBILE)", category: "imobile",
      visible: true, locked: false, opacity: 1.0,
      stroke_color: "#111827", fill_color: "rgba(255, 255, 255, 0.4)",
      stroke_width: 1.2, stroke_dash: "solid", z_index: 200,
      color_by_category: true
    },
    "cladiri" => {
      display_name: "Clădiri (CONSTRUCTII)", category: "constructii",
      visible: true, locked: false, opacity: 1.0,
      stroke_color: "#831843", fill_color: "rgba(244, 114, 182, 0.25)",
      stroke_width: 1.0, stroke_dash: "solid", z_index: 300
    },
    "parcele_labels" => {
      display_name: "Etichete parcele (nr cad + supraf.)", category: "labels",
      visible: true, locked: false, opacity: 1.0, z_index: 1200
    },
    "cladiri_labels" => {
      display_name: "Etichete clădiri", category: "labels",
      visible: true, locked: false, opacity: 1.0, z_index: 1200
    },
    "cgxml_labels" => {
      display_name: "Etichete CGXML", category: "labels",
      visible: true, locked: false, opacity: 1.0, z_index: 1200
    }
  }.freeze

  VALID_KEYS  = DEFAULTS.keys.freeze
  VALID_DASH  = %w[solid dashed dotted dash-dot].freeze

  validates :owner_token, presence: true
  validates :layer_key,   presence: true, inclusion: { in: VALID_KEYS }
  validates :opacity,     numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validates :stroke_dash, inclusion: { in: VALID_DASH }, allow_nil: true

  scope :for_owner, ->(token) { where(owner_token: token) }

  # Întoarce hash cheie→config (merged: default + suprapunere user) pentru
  # toate layer-ele cunoscute, indiferent dacă există row în DB sau nu.
  def self.full_prefs_for(owner_token)
    overrides = for_owner(owner_token).index_by(&:layer_key)
    DEFAULTS.map do |key, defaults|
      pref = overrides[key]
      [key, merged_config(key, defaults, pref)]
    end.to_h
  end

  # Merge: pentru fiecare cheie, valoarea NULL în pref ⇒ folosește default-ul.
  # Asta permite PATCH-uri parțiale (ex: doar `opacity`) fără a suprascrie
  # restul atributelor (visible/locked/color_by_category) cu valori coloană
  # DEFAULT care diferă de default-urile per-layer din `DEFAULTS`.
  def self.merged_config(key, defaults, pref)
    base = defaults.merge(layer_key: key)
    return base unless pref

    base.merge(
      visible:           pref.visible.nil?           ? defaults[:visible]           : pref.visible,
      locked:            pref.locked.nil?            ? defaults[:locked]            : pref.locked,
      opacity:           pref.opacity.nil?           ? defaults[:opacity]           : pref.opacity,
      stroke_color:      pref.stroke_color.presence      || defaults[:stroke_color],
      fill_color:        pref.fill_color.presence        || defaults[:fill_color],
      stroke_width:      pref.stroke_width               || defaults[:stroke_width],
      stroke_dash:       pref.stroke_dash.presence       || defaults[:stroke_dash],
      z_index:           pref.z_index                    || defaults[:z_index],
      color_by_category: pref.color_by_category.nil? ? defaults[:color_by_category] : pref.color_by_category,
      min_resolution:    pref.min_resolution,
      max_resolution:    pref.max_resolution
    )
  end
end
