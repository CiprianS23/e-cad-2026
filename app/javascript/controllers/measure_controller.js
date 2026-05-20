import { Controller } from "@hotwired/stimulus"

// Unealtă de măsurare distanțe / arii. Folosește OL Draw (LineString sau
// Polygon) și calculează direct în EPSG:3844 (Stereo70 — metric nativ).
// Etichete persistente pe segmente + total. ESC anulează schița curentă.
export default class extends Controller {
  static outlets = ["harta-map"]
  static targets = ["btnDistance", "btnArea", "btnClear", "result"]

  connect() {
    this._mode = null
    this._sketchListenerKey = null
    this._attached = false

    this._onKeyDown = (e) => this._handleKey(e)
    document.addEventListener("keydown", this._onKeyDown)
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKeyDown)
    this._detach()
  }

  hartaMapOutletConnected(outlet) {
    this._outlet = outlet
    const attach = () => this._attach()
    if (outlet.map) attach()
    else outlet.element.addEventListener("harta-map:ready", attach, { once: true })
  }

  hartaMapOutletDisconnected() { this._detach() }

  // Layer-ele și overlay-ul se creează LAZY aici, după ce harta e gata.
  // Asta evită race-uri unde OL itera o colecție de layere parțial inițializată.
  _attach() {
    if (this._attached) return
    const map = this._outlet?.map
    if (!map) return
    this.map = map

    this._sketchSource = new ol.source.Vector()
    this._sketchLayer  = new ol.layer.Vector({
      source: this._sketchSource,
      style:  this._sketchStyle.bind(this),
      properties: { name: "measure-sketch" },
      zIndex: 1500
    })

    this._finalSource = new ol.source.Vector()
    this._finalLayer  = new ol.layer.Vector({
      source: this._finalSource,
      style:  this._finalStyle.bind(this),
      properties: { name: "measure-final" },
      zIndex: 1499
    })

    this._labelsSource = new ol.source.Vector()
    this._labelsLayer  = new ol.layer.Vector({
      source: this._labelsSource,
      style:  this._labelStyle.bind(this),
      properties: { name: "measure-labels" },
      zIndex: 1501
    })

    this.map.addLayer(this._finalLayer)
    this.map.addLayer(this._sketchLayer)
    this.map.addLayer(this._labelsLayer)

    this._tooltipEl = document.createElement("div")
    this._tooltipEl.className = "measure-tooltip"
    this._tooltipOverlay = new ol.Overlay({
      element: this._tooltipEl,
      offset: [12, 0],
      positioning: "center-left",
      stopEvent: false
    })
    this.map.addOverlay(this._tooltipOverlay)
    this._hideTooltip()
    this._attached = true
  }

  _detach() {
    if (!this._attached) {
      this._outlet = null
      this.map = null
      return
    }
    this._cancel({ silent: true })
    if (this.map) {
      if (this._tooltipOverlay) this.map.removeOverlay(this._tooltipOverlay)
      if (this._finalLayer)  this.map.removeLayer(this._finalLayer)
      if (this._sketchLayer) this.map.removeLayer(this._sketchLayer)
      if (this._labelsLayer) this.map.removeLayer(this._labelsLayer)
    }
    this._sketchSource = this._sketchLayer = null
    this._finalSource  = this._finalLayer  = null
    this._labelsSource = this._labelsLayer = null
    this._tooltipEl    = this._tooltipOverlay = null
    this._attached = false
    this.map = null
    this._outlet = null
  }

  // ── Public actions ──────────────────────────────────────────────────────

  startDistance() {
    if (this._mode === "distance") return this._cancel()
    this._start("distance")
  }

  startArea() {
    if (this._mode === "area") return this._cancel()
    this._start("area")
  }

  clearAll() {
    this._cancel({ silent: true })
    if (this._finalSource)  this._finalSource.clear()
    if (this._labelsSource) this._labelsSource.clear()
    if (this.hasResultTarget) this.resultTarget.textContent = ""
  }

  _start(mode) {
    if (!this.map) return
    this._cancel({ silent: true })
    this._mode = mode
    this._setActiveButtons()
    this._outlet?.setDigitizing?.(true)

    const type = mode === "area" ? "Polygon" : "LineString"
    this._draw = new ol.interaction.Draw({
      source: this._sketchSource,
      type,
      style: this._sketchStyle.bind(this)
    })
    this._draw.on("drawstart", (e) => this._onDrawStart(e))
    this._draw.on("drawend",   (e) => this._onDrawEnd(e))
    this.map.addInteraction(this._draw)
    // Snap se adaugă DUPĂ Draw (cerință OL: Snap trebuie ultimul în pipeline).
    this._refreshSnap()

    if (this.hasResultTarget) {
      this.resultTarget.textContent = mode === "area"
        ? "Click pentru vertecși, dublu-click închide poligonul. ESC = anulează schița."
        : "Click pentru vertecși, dublu-click finalizează. ESC = anulează schița."
    }
  }

  // ── OSnap ───────────────────────────────────────────────────────────────
  // Reutilizează modurile/toleranța setate de utilizator în statusbar-ul digi
  // (persistate via localStorage); fallback la endpoint+midpoint, tol 15px.
  _refreshSnap() {
    if (!this.map) return
    if (this._snap) {
      this.map.removeInteraction(this._snap)
      this._snap = null
    }
    const modes     = this._readSnapModes()
    const tolerance = this._readSnapTolerance()
    const features  = this._buildSnapFeatures(modes)
    this._snap = new ol.interaction.Snap({
      features:       new ol.Collection(features),
      pixelTolerance: tolerance,
      vertex:         modes.has("endpoint") || modes.has("midpoint") || modes.has("centroid"),
      edge:           modes.has("nearest")
    })
    this._snap.setActive(this._readSnapEnabled())
    this.map.addInteraction(this._snap)
  }

  _readSnapEnabled() {
    const btn = document.querySelector('[data-digitizare-target="snapToggle"]')
    if (!btn) return true
    return btn.classList.contains("cad-status-toggle--on")
  }

  _readSnapModes() {
    try {
      const raw = localStorage.getItem("harta:snapModes")
      if (raw) {
        const arr = JSON.parse(raw)
        if (Array.isArray(arr) && arr.length) return new Set(arr)
      }
    } catch (_) {}
    return new Set(["endpoint", "midpoint"])
  }

  _readSnapTolerance() {
    const slider = document.querySelector('[data-digitizare-target="snapSlider"]')
    const v = slider ? parseInt(slider.value, 10) : NaN
    return Number.isFinite(v) ? v : 15
  }

  _buildSnapFeatures(modes) {
    const out    = []
    const layers = [
      this._outlet?.parcelLayer,
      this._outlet?.cgxmlLayer,
      this._outlet?.cladiriLayer,
      this._finalLayer   // permite snap la măsurătorile anterioare
    ].filter(Boolean)
    layers.forEach(layer => {
      const src = layer.getSource?.()
      if (!src) return
      src.getFeatures().forEach(f => {
        if (modes.has("endpoint") || modes.has("nearest")) out.push(f)
        if (modes.has("midpoint")) this._addMidpoints(f, out)
        if (modes.has("centroid")) this._addCentroid(f, out)
      })
    })
    return out
  }

  _addMidpoints(feature, out) {
    const geom = feature.getGeometry()
    if (!geom) return
    const t = geom.getType()
    let rings = []
    if (t === "Polygon")           rings = geom.getCoordinates()
    else if (t === "MultiPolygon") rings = geom.getCoordinates().flat()
    else if (t === "LineString")   rings = [geom.getCoordinates()]
    rings.forEach(ring => {
      for (let i = 0; i < ring.length - 1; i++) {
        const mx = (ring[i][0] + ring[i + 1][0]) / 2
        const my = (ring[i][1] + ring[i + 1][1]) / 2
        out.push(new ol.Feature(new ol.geom.Point([mx, my])))
      }
    })
  }

  _addCentroid(feature, out) {
    const geom = feature.getGeometry()
    if (!geom) return
    const ext = geom.getExtent()
    const center = ol.extent.getCenter(ext)
    out.push(new ol.Feature(new ol.geom.Point(center)))
  }

  _cancel({ silent = false } = {}) {
    if (this._draw && this.map) {
      try { this._draw.abortDrawing() } catch (_) {}
      this.map.removeInteraction(this._draw)
      this._draw = null
    }
    if (this._snap && this.map) {
      this.map.removeInteraction(this._snap)
      this._snap = null
    }
    if (this._sketchSource) this._sketchSource.clear()
    this._hideTooltip()
    if (this._sketchListenerKey) {
      ol.Observable.unByKey(this._sketchListenerKey)
      this._sketchListenerKey = null
    }
    if (this._mode) {
      this._mode = null
      this._setActiveButtons()
      this._outlet?.setDigitizing?.(false)
    }
    if (!silent && this.hasResultTarget) this.resultTarget.textContent = ""
  }

  _handleKey(e) {
    if (!this._draw) return
    // Ignoră tastele când utilizatorul tastează într-un input/textarea
    const tag = (e.target && e.target.tagName) || ""
    if (tag === "INPUT" || tag === "TEXTAREA" || e.target?.isContentEditable) return

    // Backspace sau Ctrl/Cmd+Z → șterge ultimul vertex (rămâi în desen)
    if (e.key === "Backspace" || ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "z")) {
      e.preventDefault()
      try { this._draw.removeLastPoint() } catch (_) {}
      // Dacă nu mai sunt vertecși, OL ascunde schița; ascundem și tooltip-ul.
      if (this._sketchSource && this._sketchSource.getFeatures().length === 0) {
        this._hideTooltip()
      }
      return
    }

    if (e.key === "Escape") {
      // ESC: anulează schița curentă, dar rămâi în modul de măsurare.
      try { this._draw.abortDrawing() } catch (_) {}
      if (this._sketchSource) this._sketchSource.clear()
      this._hideTooltip()
      if (this._sketchListenerKey) {
        ol.Observable.unByKey(this._sketchListenerKey)
        this._sketchListenerKey = null
      }
    }
  }

  _onDrawStart(evt) {
    const sketch = evt.feature
    this._sketchListenerKey = sketch.getGeometry().on("change", (e) => {
      this._updateLiveTooltip(e.target)
    })
  }

  _onDrawEnd(evt) {
    if (this._sketchListenerKey) {
      ol.Observable.unByKey(this._sketchListenerKey)
      this._sketchListenerKey = null
    }
    this._hideTooltip()
    this._sketchSource.clear()

    const feat = evt.feature
    const geom = feat.getGeometry()
    if (!geom) return
    const isPolygon = geom instanceof ol.geom.Polygon
    feat.set("measureKind", isPolygon ? "area" : "distance")
    this._finalSource.addFeature(feat)

    this._addSegmentLabels(geom)

    if (isPolygon) {
      const area      = geom.getArea()
      const ring      = geom.getLinearRing(0)
      const perimeter = this._ringLength(ring.getCoordinates())
      const center    = geom.getInteriorPoint().getCoordinates()
      this._addTotalLabel(center, this._formatArea(area), `perim: ${this._formatLength(perimeter)}`)
      if (this.hasResultTarget) {
        this.resultTarget.textContent = `Arie: ${this._formatArea(area)} · Perimetru: ${this._formatLength(perimeter)}`
      }
    } else {
      const length = geom.getLength()
      const coords = geom.getCoordinates()
      this._addTotalLabel(coords[coords.length - 1], `Total: ${this._formatLength(length)}`, null)
      if (this.hasResultTarget) {
        this.resultTarget.textContent = `Distanță: ${this._formatLength(length)}`
      }
    }
    // Rebuild snap: includem și măsurătoarea tocmai finalizată ca țintă pentru snap.
    if (this._draw) this._refreshSnap()
    // Rămâi în același mod pentru măsurători consecutive — buton sau ESC pentru ieșire.
  }

  _updateLiveTooltip(geom) {
    let pos, text
    if (geom instanceof ol.geom.Polygon) {
      const ring   = geom.getLinearRing(0)
      const coords = ring.getCoordinates()
      // Ring: [v1, ..., vN, cursor, v1]. Cu < 2 vertecși clickați (length < 4),
      // poligonul e degenerat (arie 0) — afișează doar lungimea spre cursor.
      if (coords.length < 4) {
        if (coords.length < 2) return
        pos  = coords[coords.length - 2]
        text = this._formatLength(this._distance(coords[0], pos))
      } else {
        pos = coords[coords.length - 2]
        const area  = geom.getArea()
        const perim = this._ringLength(coords)
        text = `${this._formatArea(area)}  ·  perim ${this._formatLength(perim)}`
      }
    } else {
      const coords = geom.getCoordinates()
      if (coords.length < 1) return
      pos = coords[coords.length - 1]
      const len = geom.getLength()
      let segText = ""
      if (coords.length >= 2) {
        const seg = this._distance(coords[coords.length - 2], pos)
        segText = `  (Δ ${this._formatLength(seg)})`
      }
      text = `${this._formatLength(len)}${segText}`
    }
    this._showTooltip(pos, text)
  }

  _addSegmentLabels(geom) {
    const coords = (geom instanceof ol.geom.Polygon)
      ? geom.getLinearRing(0).getCoordinates()
      : geom.getCoordinates()
    for (let i = 0; i < coords.length - 1; i++) {
      const a   = coords[i]
      const b   = coords[i + 1]
      const len = this._distance(a, b)
      if (len < 0.01) continue
      const mid = [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2]
      // În Stereo70 axa Y crește spre N; OL randează cu Y inversat pe ecran,
      // deci rotația textului (pozitivă orară pe ecran) e -unghi_geografic.
      const rot = this._normalizeRotation(-Math.atan2(b[1] - a[1], b[0] - a[0]))
      const feat = new ol.Feature(new ol.geom.Point(mid))
      feat.set("measureSegmentLabel", true)
      feat.set("text", this._formatLength(len))
      feat.set("rotation", rot)
      this._labelsSource.addFeature(feat)
    }
  }

  _addTotalLabel(pos, line1, line2) {
    const feat = new ol.Feature(new ol.geom.Point(pos))
    feat.set("measureTotalLabel", true)
    feat.set("text", line2 ? `${line1}\n${line2}` : line1)
    this._labelsSource.addFeature(feat)
  }

  _normalizeRotation(rot) {
    let r = rot
    while (r >  Math.PI / 2) r -= Math.PI
    while (r < -Math.PI / 2) r += Math.PI
    return r
  }

  _showTooltip(pos, text) {
    if (!this._tooltipEl) return
    this._tooltipEl.textContent = text
    this._tooltipEl.style.display = ""
    this._tooltipOverlay.setPosition(pos)
  }

  _hideTooltip() {
    if (this._tooltipEl) this._tooltipEl.style.display = "none"
    if (this._tooltipOverlay) this._tooltipOverlay.setPosition(undefined)
  }

  _setActiveButtons() {
    const set = (target, active) => {
      if (!target) return
      target.classList.toggle("btn-active", active)
      target.setAttribute("aria-pressed", active ? "true" : "false")
    }
    set(this.hasBtnDistanceTarget ? this.btnDistanceTarget : null, this._mode === "distance")
    set(this.hasBtnAreaTarget     ? this.btnAreaTarget     : null, this._mode === "area")
  }

  _distance(a, b) {
    const dx = b[0] - a[0]
    const dy = b[1] - a[1]
    return Math.sqrt(dx * dx + dy * dy)
  }

  // OL LinearRing nu expune `getLength()` — calculăm manual perimetrul ca
  // sumă de distanțe euclidiene între vertecși consecutivi (corect în Stereo70).
  _ringLength(coords) {
    if (!coords || coords.length < 2) return 0
    let total = 0
    for (let i = 0; i < coords.length - 1; i++) {
      total += this._distance(coords[i], coords[i + 1])
    }
    return total
  }

  _formatLength(m) {
    if (m >= 1000) {
      return `${(m / 1000).toLocaleString("ro-RO", { minimumFractionDigits: 3, maximumFractionDigits: 3 })} km`
    }
    if (m >= 100) {
      return `${m.toLocaleString("ro-RO", { minimumFractionDigits: 1, maximumFractionDigits: 1 })} m`
    }
    return `${m.toLocaleString("ro-RO", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} m`
  }

  _formatArea(m2) {
    if (m2 >= 1_000_000) {
      const km2 = (m2 / 1_000_000).toLocaleString("ro-RO", { minimumFractionDigits: 3, maximumFractionDigits: 3 })
      const mp  = m2.toLocaleString("ro-RO", { maximumFractionDigits: 0 })
      return `${km2} km² (${mp} mp)`
    }
    if (m2 >= 10000) {
      const ha = (m2 / 10000).toLocaleString("ro-RO", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
      const mp = m2.toLocaleString("ro-RO", { maximumFractionDigits: 1 })
      return `${ha} ha (${mp} mp)`
    }
    return `${m2.toLocaleString("ro-RO", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} mp`
  }

  // ── Styles ──────────────────────────────────────────────────────────────

  _sketchStyle() {
    return new ol.style.Style({
      stroke: new ol.style.Stroke({ color: "#dc2626", width: 2.5, lineDash: [8, 4] }),
      fill:   new ol.style.Fill({ color: "rgba(220, 38, 38, 0.10)" }),
      image:  new ol.style.Circle({
        radius: 5,
        fill:   new ol.style.Fill({ color: "#dc2626" }),
        stroke: new ol.style.Stroke({ color: "#fff", width: 2 })
      })
    })
  }

  _finalStyle(feat) {
    const kind = feat.get("measureKind")
    if (kind === "area") {
      return new ol.style.Style({
        stroke: new ol.style.Stroke({ color: "#b91c1c", width: 2 }),
        fill:   new ol.style.Fill({ color: "rgba(220, 38, 38, 0.10)" })
      })
    }
    return new ol.style.Style({
      stroke: new ol.style.Stroke({ color: "#b91c1c", width: 2.5 }),
      image:  new ol.style.Circle({
        radius: 4,
        fill:   new ol.style.Fill({ color: "#b91c1c" }),
        stroke: new ol.style.Stroke({ color: "#fff", width: 1.5 })
      })
    })
  }

  _labelStyle(feat) {
    const text = feat.get("text") || ""
    if (feat.get("measureTotalLabel")) {
      return new ol.style.Style({
        text: new ol.style.Text({
          text,
          font:             "700 13px system-ui, sans-serif",
          fill:             new ol.style.Fill({ color: "#7f1d1d" }),
          stroke:           new ol.style.Stroke({ color: "#ffffff", width: 4 }),
          backgroundFill:   new ol.style.Fill({ color: "rgba(255,255,255,0.92)" }),
          backgroundStroke: new ol.style.Stroke({ color: "#b91c1c", width: 1 }),
          padding:          [4, 6, 4, 6],
          textAlign:        "center",
          overflow:         true
        })
      })
    }
    return new ol.style.Style({
      text: new ol.style.Text({
        text,
        font:      "600 11px system-ui, sans-serif",
        fill:      new ol.style.Fill({ color: "#7f1d1d" }),
        stroke:    new ol.style.Stroke({ color: "#ffffff", width: 3 }),
        textAlign: "center",
        rotation:  feat.get("rotation") || 0,
        offsetY:   -8,
        overflow:  true
      })
    })
  }
}
