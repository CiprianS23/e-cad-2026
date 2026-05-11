import { Controller } from "@hotwired/stimulus"

// Layer Manager — QGIS-like.
// - Listă layere (vizibilitate, lock, opacitate, culoare contur/fill, grosime, tip linie)
// - Drag & drop reordonare (z-index)
// - Persistență prin /gis/layer_prefs (cookie owner_token)
// - Outlet pe harta-map: aplică configurațiile pe layer-ele OpenLayers
//
// Layout HTML așteptat:
//   <div data-controller="layer-manager" data-layer-manager-harta-map-outlet="#harta-map">
//     <div data-layer-manager-target="baseLayers">… (radio "Hartă de bază")</div>
//     <ol  data-layer-manager-target="list"></ol>
//     <button data-action="layer-manager#resetAll" data-layer-manager-target="resetBtn">Reset</button>
//   </div>
export default class extends Controller {
  static outlets = ["harta-map"]
  static targets = ["list", "baseLayers"]

  connect() {
    this._prefs        = {}
    this._loaded       = false
    this._mapReady     = false
    this._draggedKey   = null
    this._csrf         = document.querySelector('meta[name="csrf-token"]')?.content
    this._fetchPrefs()
  }

  hartaMapOutletConnected(outlet) {
    if (outlet.map) this._onMapReady()
    else outlet.element.addEventListener("harta-map:ready", () => this._onMapReady(), { once: true })
    // Planurile raster georeferențiate se încarcă async — re-aplicăm config-ul
    // și re-render listă când sosesc.
    outlet.element.addEventListener("harta-map:georef-loaded", () => {
      this._fetchPrefs()  // re-render lista (include planurile noi în UI)
    })
  }

  _onMapReady() {
    this._mapReady = true
    if (this._loaded) this._applyAllToMap()
    // Aplicăm starea de bază (radio "Hartă de bază") imediat la conectare
    const baseChecked = this.element.querySelector('input[name="base-layer"]:checked')
    if (baseChecked && this.hasHartaMapOutlet) this.hartaMapOutlet.setBaseLayer(baseChecked.value)
  }

  selectBase(event) {
    this.hartaMapOutlet?.setBaseLayer(event.target.value)
  }

  async _fetchPrefs() {
    try {
      const r = await fetch("/gis/layer_prefs", {
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
      const data = await r.json()
      this._prefs = data.layers || {}
      this._loaded = true
      this._render()
      if (this._mapReady) this._applyAllToMap()
    } catch (e) {
      console.error("Layer Manager: nu pot încărca preferințele", e)
    }
  }

  _applyAllToMap() {
    if (!this.hasHartaMapOutlet) return
    Object.entries(this._prefs).forEach(([key, cfg]) => {
      this.hartaMapOutlet.applyLayerConfig(key, cfg)
    })
  }

  _render() {
    if (!this.hasListTarget) return
    // Layer-ele de etichete (parcele_labels etc.) NU apar ca rânduri separate —
    // sunt randate ca sub-secțiune în props-ul layer-ului părinte.
    const isLabelKey = (k) => k.endsWith("_labels")
    const entries = Object.entries(this._prefs)
      .filter(([k]) => !isLabelKey(k))
      .sort((a, b) => (b[1].z_index || 0) - (a[1].z_index || 0))
    this.listTarget.innerHTML = entries.map(([key, cfg]) => this._rowHtml(key, cfg)).join("")
    this._bindRowEvents()
  }

  _rowHtml(key, cfg) {
    const displayName    = cfg.display_name || key
    const category       = cfg.category || "—"
    const visible        = cfg.visible !== false
    const locked         = !!cfg.locked
    const opacity        = cfg.opacity != null ? cfg.opacity : 1
    const opacityPct     = Math.round(opacity * 100)
    const strokeColor    = this._asHexColor(cfg.stroke_color) || "#1d4ed8"
    const fillColor      = this._asHexColor(cfg.fill_color)   || "#ffffff"
    const strokeWidth    = cfg.stroke_width != null ? cfg.stroke_width : 1.5
    const strokeDash     = cfg.stroke_dash || "solid"
    const colorByCat     = !!cfg.color_by_category
    const isLabelsLayer  = key.endsWith("_labels")
    const isRaster       = category === "raster"
    const labelsSubHtml  = this._labelsSubHtml(key)

    return `
      <li class="lm-row" draggable="true"
          data-key="${key}"
          data-category="${category}"
          data-action="dragstart->layer-manager#onDragStart dragover->layer-manager#onDragOver drop->layer-manager#onDrop dragend->layer-manager#onDragEnd">
        <div class="lm-row-head">
          <span class="lm-drag-handle" title="Trage pentru reordonare">☰</span>
          <label class="lm-toggle lm-vis" title="Vizibilitate">
            <input type="checkbox" data-action="change->layer-manager#toggleVisible" ${visible ? "checked" : ""}>
            <span>👁</span>
          </label>
          <label class="lm-toggle lm-lock" title="${locked ? "Layer blocat (editare interzisă)" : "Layer editabil"}">
            <input type="checkbox" data-action="change->layer-manager#toggleLocked" ${locked ? "checked" : ""}>
            <span>${locked ? "🔒" : "🔓"}</span>
          </label>
          <button type="button" class="lm-swatch" title="Stil layer"
                  style="background:${this._swatchBackground(cfg)};border-color:${strokeColor}"
                  data-action="click->layer-manager#toggleProps"></button>
          <span class="lm-name" title="Click pentru stil layer"
                data-action="click->layer-manager#toggleProps">${displayName}</span>
          <button type="button" class="lm-expand" title="Extinde proprietăți"
                  data-action="click->layer-manager#toggleProps">▸</button>
          <button type="button" class="lm-zoom" title="Zoom la layer"
                  data-action="click->layer-manager#zoomToLayer">⌖</button>
        </div>
        <div class="lm-props" hidden>
          <label class="lm-prop">
            <span>Opacitate</span>
            <input type="range" min="0" max="100" value="${opacityPct}"
                   data-action="input->layer-manager#changeOpacity">
            <output>${opacityPct}%</output>
          </label>
          ${ isRaster ? `
          <label class="lm-prop lm-prop--checkbox">
            <input type="checkbox" ${cfg.bg_transparent !== false ? "checked" : ""}
                   data-action="change->layer-manager#changeBgTransparent">
            <span>Ascunde fundalul alb (păstrează doar liniile/textul)</span>
          </label>
          ` : "" }
          ${ (isLabelsLayer || isRaster) ? "" : `
          <label class="lm-prop">
            <span>Culoare contur</span>
            <input type="color" value="${strokeColor}"
                   data-action="change->layer-manager#changeStrokeColor">
          </label>
          <label class="lm-prop">
            <span>Culoare umplutură</span>
            <input type="color" value="${fillColor}"
                   data-action="change->layer-manager#changeFillColor">
          </label>
          <label class="lm-prop">
            <span>Grosime contur (px)</span>
            <input type="number" min="0" max="10" step="0.1" value="${strokeWidth}"
                   data-action="change->layer-manager#changeStrokeWidth">
          </label>
          <label class="lm-prop">
            <span>Tip linie</span>
            <select data-action="change->layer-manager#changeStrokeDash">
              <option value="solid"   ${strokeDash === "solid"   ? "selected" : ""}>continuu</option>
              <option value="dashed"  ${strokeDash === "dashed"  ? "selected" : ""}>întrerupt</option>
              <option value="dotted"  ${strokeDash === "dotted"  ? "selected" : ""}>punctat</option>
              <option value="dash-dot" ${strokeDash === "dash-dot" ? "selected" : ""}>linie-punct</option>
            </select>
          </label>
          ${ key === "parcele" ? `
          <label class="lm-prop lm-prop--checkbox">
            <input type="checkbox" ${colorByCat ? "checked" : ""}
                   data-action="change->layer-manager#changeColorByCategory">
            <span>Culoare după categoria de folosință</span>
          </label>
          ` : "" }
          `}
          ${labelsSubHtml}
          <button type="button" class="lm-prop-reset"
                  data-action="click->layer-manager#resetLayer">↺ Default</button>
        </div>
      </li>`
  }

  // Sub-secțiune "Etichete" în props-ul layer-ului părinte (vizibilitate +
  // opacitate). Tratează `<parent>_labels` ca o configurație inclusă, nu un
  // layer separat în lista vizibilă.
  _labelsSubHtml(parentKey) {
    const labelKey = `${parentKey}_labels`
    const cfg      = this._prefs[labelKey]
    if (!cfg) return ""
    const visible    = cfg.visible !== false
    const opacityPct = Math.round((cfg.opacity != null ? cfg.opacity : 1) * 100)
    return `
      <div class="lm-sub" data-sub-key="${labelKey}">
        <div class="lm-sub-head">
          <label class="lm-toggle lm-vis" title="Etichete vizibile">
            <input type="checkbox" data-action="change->layer-manager#toggleSubVisible" ${visible ? "checked" : ""}>
            <span>👁</span>
          </label>
          <span class="lm-sub-name">Etichete (nr cad + supraf.)</span>
        </div>
        <label class="lm-prop">
          <span>Opacitate etichete</span>
          <input type="range" min="0" max="100" value="${opacityPct}"
                 data-action="input->layer-manager#changeSubOpacity">
          <output>${opacityPct}%</output>
        </label>
      </div>`
  }

  toggleSubVisible(event) {
    const subKey = event.target.closest(".lm-sub")?.dataset.subKey
    if (!subKey) return
    this._patch(subKey, { visible: event.target.checked })
  }

  changeSubOpacity(event) {
    const subKey = event.target.closest(".lm-sub")?.dataset.subKey
    if (!subKey) return
    const pct = parseInt(event.target.value, 10)
    const out = event.target.parentElement.querySelector("output")
    if (out) out.textContent = `${pct}%`
    this._patch(subKey, { opacity: pct / 100 })
  }

  _bindRowEvents() {
    // Toggle expand props
    // (gestionat prin data-action toggleProps)
  }

  // ── Event handlers ───────────────────────────────────────────────────────

  toggleProps(event) {
    const row    = event.currentTarget.closest(".lm-row")
    const props  = row?.querySelector(".lm-props")
    const arrow  = row?.querySelector(".lm-expand")
    if (!props) return
    props.hidden = !props.hidden
    if (arrow) arrow.textContent = props.hidden ? "▸" : "▾"
    row.classList.toggle("lm-row--expanded", !props.hidden)
  }

  toggleVisible(event) {
    const key  = this._keyOf(event.target)
    this._patch(key, { visible: event.target.checked })
  }

  toggleLocked(event) {
    const key  = this._keyOf(event.target)
    this._patch(key, { locked: event.target.checked })
    // Update icon
    const span = event.target.parentElement.querySelector("span")
    if (span) span.textContent = event.target.checked ? "🔒" : "🔓"
  }

  changeOpacity(event) {
    const key = this._keyOf(event.target)
    const pct = parseInt(event.target.value, 10)
    const out = event.target.parentElement.querySelector("output")
    if (out) out.textContent = `${pct}%`
    this._patch(key, { opacity: pct / 100 })
  }

  changeStrokeColor(event) {
    const key = this._keyOf(event.target)
    this._patch(key, { stroke_color: event.target.value })
    this._refreshSwatch(key)
  }

  changeFillColor(event) {
    const key = this._keyOf(event.target)
    this._patch(key, { fill_color: event.target.value })
    this._refreshSwatch(key)
  }

  changeStrokeWidth(event) {
    const key = this._keyOf(event.target)
    this._patch(key, { stroke_width: parseFloat(event.target.value) || 0 })
  }

  changeStrokeDash(event) {
    const key = this._keyOf(event.target)
    this._patch(key, { stroke_dash: event.target.value })
  }

  changeColorByCategory(event) {
    const key = this._keyOf(event.target)
    this._patch(key, { color_by_category: event.target.checked })
    this._refreshSwatch(key)
  }

  changeBgTransparent(event) {
    const key = this._keyOf(event.target)
    this._patch(key, { bg_transparent: event.target.checked })
  }

  zoomToLayer(event) {
    const key = this._keyOf(event.target)
    if (!this.hasHartaMapOutlet) return
    const ok = this.hartaMapOutlet.zoomToLayer(key)
    if (!ok) console.warn("Layer fără geometrii, nu pot face zoom:", key)
  }

  resetLayer(event) {
    if (!confirm("Restaurează valorile implicite pentru acest layer?")) return
    const key = this._keyOf(event.target)
    // Trimitem PATCH cu corpul "gol" pentru a deciziona: server-side ar trebui
    // să șteargă row-ul → fallback la default. Soluție mai curată = endpoint
    // dedicat per cheie, dar pentru MVP: PATCH cu valori NULL.
    fetch(`/gis/layer_prefs/${key}`, {
      method: "PATCH",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf, Accept: "application/json" },
      body: JSON.stringify({
        visible: true, locked: false, opacity: 1.0,
        stroke_color: "", fill_color: "", stroke_dash: "", color_by_category: false
      })
    }).then(() => this._fetchPrefs())
  }

  resetAll() {
    if (!confirm("Restaurează valorile implicite pentru toate layer-ele?")) return
    fetch("/gis/layer_prefs", {
      method: "DELETE",
      credentials: "same-origin",
      headers: { "X-CSRF-Token": this._csrf, Accept: "application/json" }
    }).then(() => this._fetchPrefs())
  }

  // ── Drag & drop reordonare ──────────────────────────────────────────────

  onDragStart(event) {
    this._draggedKey = event.currentTarget.dataset.key
    event.currentTarget.classList.add("lm-row--dragging")
    event.dataTransfer.effectAllowed = "move"
  }

  onDragOver(event) {
    event.preventDefault()
    event.dataTransfer.dropEffect = "move"
    event.currentTarget.classList.add("lm-row--drop-target")
  }

  onDrop(event) {
    event.preventDefault()
    event.currentTarget.classList.remove("lm-row--drop-target")
    const fromKey = this._draggedKey
    const toKey   = event.currentTarget.dataset.key
    if (!fromKey || !toKey || fromKey === toKey) return

    // Calculează noi z-index-uri: orderea vizuală se mapează la valori
    // descrescătoare (sus = z mare). Reordonăm array-ul de chei vizibile.
    const rows = Array.from(this.listTarget.querySelectorAll(".lm-row"))
    const keys = rows.map(r => r.dataset.key)
    const fromIdx = keys.indexOf(fromKey)
    const toIdx   = keys.indexOf(toKey)
    if (fromIdx === -1 || toIdx === -1) return
    keys.splice(fromIdx, 1)
    keys.splice(toIdx, 0, fromKey)
    // Reasignăm z-index: primul în listă (sus) primește valoarea maximă
    const maxZ = 1500
    const step = 100
    keys.forEach((k, i) => {
      const newZ = maxZ - i * step
      this._patch(k, { z_index: newZ }, { silent: true })
    })
    this._render()
  }

  onDragEnd(event) {
    event.currentTarget.classList.remove("lm-row--dragging")
    this.element.querySelectorAll(".lm-row--drop-target").forEach(el => el.classList.remove("lm-row--drop-target"))
    this._draggedKey = null
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  _keyOf(el) {
    return el.closest(".lm-row")?.dataset.key
  }

  _patch(key, attrs, opts = {}) {
    if (!key) return
    // Update local optimist și aplică pe hartă imediat (UX rapid)
    this._prefs[key] = { ...(this._prefs[key] || {}), ...attrs }
    this.hartaMapOutlet?.applyLayerConfig(key, this._prefs[key])

    // Persistă pe server (fire-and-forget)
    fetch(`/gis/layer_prefs/${key}`, {
      method: "PATCH",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf, Accept: "application/json" },
      body: JSON.stringify(attrs)
    }).then(r => {
      if (!r.ok) console.warn(`Layer Manager: PATCH ${key} eșuat`, r.status)
    }).catch(e => console.warn("Layer Manager: PATCH eroare", e))
  }

  _refreshSwatch(key) {
    const row = this.listTarget.querySelector(`.lm-row[data-key="${key}"]`)
    const sw  = row?.querySelector(".lm-swatch")
    if (!sw) return
    const cfg = this._prefs[key] || {}
    sw.style.background   = this._swatchBackground(cfg)
    sw.style.borderColor  = this._asHexColor(cfg.stroke_color) || "#1d4ed8"
  }

  _swatchBackground(cfg) {
    if (cfg.color_by_category) {
      return "linear-gradient(45deg, #22c55e, #a855f7, #f97316)"
    }
    const f = this._asHexColor(cfg.fill_color)
    return f || "rgba(255,255,255,0.4)"
  }

  // Normalizează culorile pentru <input type="color"> care acceptă DOAR #RRGGBB.
  _asHexColor(c) {
    if (!c) return null
    if (c === "transparent") return null
    if (c.startsWith("#") && c.length === 7) return c
    // rgba(r,g,b,a) sau rgb(r,g,b)
    const m = c.match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/)
    if (m) {
      const hex = (n) => parseInt(n, 10).toString(16).padStart(2, "0")
      return `#${hex(m[1])}${hex(m[2])}${hex(m[3])}`
    }
    return null
  }
}
