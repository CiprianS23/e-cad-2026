import { Controller } from "@hotwired/stimulus"

const FMT  = (n) => Number(n).toLocaleString("ro-RO", { minimumFractionDigits: 3, maximumFractionDigits: 3 })
const FMT2 = (n) => Number(n).toLocaleString("ro-RO", { minimumFractionDigits: 2, maximumFractionDigits: 2 })

export default class extends Controller {
  static outlets = ["harta-map"]

  static values = {
    calcUrl:       String,
    exportDxfUrl:  String,
    locateUatUrl:  String,
    snapTolerance: { type: Number, default: 15 }
  }

  static targets = [
    "panel", "panelBody",
    "snapSlider", "snapToleranceVal", "snapModes",
    "btnStart", "btnClose", "btnUndo",
    "statusBar",
    "inputX", "inputY",
    "areaCalc", "areaAct", "areaDiff",
    "topologyMsg",
    "wktField", "saveForm", "saveAreaField",
    "wktFieldCladire", "saveFormCladire", "saveAreaFieldCladire",
    "formParcela", "formCladire",
    "btnEntityParcela", "btnEntityCladire",
    "cmdInput", "cmdHint",
    "snapToggle", "orthoToggle",
    "statusX", "statusY", "statusScale", "statusArea"
  ]

  // ── Lifecycle ────────────────────────────────────────────────────────────

  connect() {
    this._verts        = []
    this._areaCalc     = 0
    this._areaDebounce = null
    this._entityType   = "parcela"
    this._snapEnabled  = true
    this._orthoEnabled = false
    this._snapModes    = new Set(["endpoint", "midpoint"])

    this._drawSource = new ol.source.Vector()
    this._drawLayer  = new ol.layer.Vector({
      source: this._drawSource,
      style:  this._drawStyle.bind(this),
      properties: { name: "digitizare" }
    })

    this._onKeyDown = (evt) => this._handleGlobalKey(evt)
    document.addEventListener("keydown", this._onKeyDown)
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKeyDown)
    this._teardown()
  }

  hartaMapOutletConnected(outlet) {
    this._hartaMap = outlet
    if (outlet.map) {
      this._attachToMap()
    } else {
      outlet.element.addEventListener("harta-map:ready", () => this._attachToMap(), { once: true })
    }
  }

  hartaMapOutletDisconnected() { this._teardown() }

  _attachToMap() {
    this.map = this._hartaMap?.map
    if (!this.map) return
    this.map.addLayer(this._drawLayer)
    this._mouseMoveKey = this.map.on("pointermove", (evt) => this._onPointerMove(evt))
    this._moveEndKey   = this.map.on("moveend",     ()    => this._updateScale())
    this._updateScale()
  }

  _teardown() {
    if (this._mouseMoveKey) ol.Observable.unByKey(this._mouseMoveKey)
    if (this._moveEndKey)   ol.Observable.unByKey(this._moveEndKey)
    if (this._draw && this.map) this.map.removeInteraction(this._draw)
    if (this._snap && this.map) this.map.removeInteraction(this._snap)
    if (this._drawLayer && this.map) this.map.removeLayer(this._drawLayer)
    this._draw = this._snap = this.map = this._hartaMap = null
  }

  // ── Public actions ───────────────────────────────────────────────────────

  togglePanel() {
    if (this.hasPanelTarget) this.panelTarget.classList.toggle("digi-panel--collapsed")
  }

  toggleSnap() {
    this._snapEnabled = !this._snapEnabled
    this.snapToggleTarget.classList.toggle("cad-status-toggle--on", this._snapEnabled)
    if (this._snap) this._snap.setActive(this._snapEnabled)
    this._setStatus(`SNAP ${this._snapEnabled ? "activ" : "oprit"}.`)
  }

  toggleOrtho() {
    this._orthoEnabled = !this._orthoEnabled
    this.orthoToggleTarget.classList.toggle("cad-status-toggle--on", this._orthoEnabled)
    this._setStatus(`ORTHO ${this._orthoEnabled ? "activ" : "oprit"}.`)
  }

  onSnapModeChange(evt) {
    const mode = evt.target.dataset.snapMode
    if (evt.target.checked) this._snapModes.add(mode)
    else this._snapModes.delete(mode)
    if (this._draw) this._refreshSnap()
  }

  onCmdKey(evt) {
    if (evt.key !== "Enter") return
    evt.preventDefault()
    const raw = this.cmdInputTarget.value.trim()
    if (!raw) return
    this.cmdInputTarget.value = ""

    if (!this._draw) { this._setStatus("Pornește digitizarea înainte să adaugi puncte.", "warn"); return }

    const pt = this._parseCmd(raw)
    if (!pt) { this._setStatus(`Format invalid: ${raw}`, "warn"); return }

    const mapCoord = ol.proj.transform([pt.x, pt.y], "EPSG:3844", "EPSG:3857")
    this._draw.appendCoordinates([mapCoord])
    this._setStatus(`Punct: X=${FMT(pt.x)}  Y=${FMT(pt.y)}`, "ok")
  }

  startDrawing() {
    if (!this.map) return
    this.clearAll()

    this._hartaMap?.setDigitizing(true)

    this._draw = new ol.interaction.Draw({
      source: this._drawSource,
      type:   "Polygon",
      style:  this._drawStyle.bind(this),
      geometryFunction: this._buildGeometryFunction()
    })
    this.map.addInteraction(this._draw)

    this._refreshSnap()

    this._draw.on("drawstart", (evt) => this._onDrawStart(evt))
    this._draw.on("drawend",   (evt) => this._onDrawEnd(evt))

    this.btnStartTarget.classList.add("btn-active")
    this.btnCloseTarget.disabled = false
    this.btnUndoTarget.disabled  = false
    this._setStatus("Clic pe hartă pentru primul vertex. Dublu-clic pentru închidere. F8=ORTHO.")
  }

  closePolygon() {
    if (!this._draw) { this._setStatus("Nu există digitizare activă.", "warn"); return }
    if (this._verts.length < 3) { this._setStatus("Sunt necesare cel puțin 3 puncte.", "warn"); return }
    this._draw.finishDrawing()
  }

  undoVertex() {
    if (!this._draw) return
    this._draw.removeLastPoint()
    if (this._verts.length > 0) this._verts.pop()
    this._updateVertexList()
    if (this._verts.length >= 3) this._calcArea()
    else { this.areaCalcTarget.textContent = "—"; this.areaDiffTarget.textContent = "—" }
    this._setStatus(`Vertex eliminat. Rămân ${this._verts.length}.`)
  }

  clearAll() {
    this._verts    = []
    this._areaCalc = 0
    if (this._draw && this.map) { this.map.removeInteraction(this._draw); this._draw = null }
    if (this._snap && this.map) { this.map.removeInteraction(this._snap); this._snap = null }
    this._hartaMap?.setDigitizing(false)
    this._drawSource.clear()
    this.btnStartTarget.classList.remove("btn-active")
    this.btnCloseTarget.disabled = true
    this.btnUndoTarget.disabled  = true
    this._updateVertexList()
    this.areaCalcTarget.textContent  = "—"
    this.areaDiffTarget.textContent  = "—"
    this.topologyMsgTarget.textContent = ""
    if (this.hasStatusAreaTarget) this.statusAreaTarget.textContent = "—"
    this._setStatus("Toți vertecșii au fost șterși.")
  }

  addManualPoint() {
    const x = parseFloat(this.inputXTarget.value)
    const y = parseFloat(this.inputYTarget.value)
    if (isNaN(x) || isNaN(y)) { this._setStatus("Coordonate invalide.", "warn"); return }
    if (!this._draw) { this._setStatus("Pornește digitizarea înainte să adaugi puncte.", "warn"); return }
    const mapCoord = ol.proj.transform([x, y], "EPSG:3844", "EPSG:3857")
    this._draw.appendCoordinates([mapCoord])
    this.inputXTarget.value = ""
    this.inputYTarget.value = ""
    this.inputXTarget.focus()
  }

  importTxt(event) {
    const file = event.target.files[0]
    if (!file) return
    if (!this._draw) { this._setStatus("Pornește digitizarea înainte să imporți.", "warn"); event.target.value = ""; return }
    const reader = new FileReader()
    reader.onload = (e) => {
      const pts = this._parseTxt(e.target.result)
      if (!pts.length) { this._setStatus("Fișier TXT fără date valide.", "warn"); return }
      const mapCoords = pts.map(({ x, y }) => ol.proj.transform([x, y], "EPSG:3844", "EPSG:3857"))
      this._draw.appendCoordinates(mapCoords)
      this._setStatus(`${pts.length} puncte importate din ${file.name}.`, "ok")
      event.target.value = ""
    }
    reader.readAsText(file)
  }

  toleranceChanged() {
    this.snapToleranceValue = parseInt(this.snapSliderTarget.value)
    this.snapToleranceValTarget.textContent = this.snapToleranceValue
    if (this._draw) this._refreshSnap()
  }

  updateDiff() { this._updateDiffDisplay() }

  async exportDxf() {
    if (this._verts.length < 2) { this._setStatus("Insuficiente puncte pentru DXF.", "warn"); return }
    try {
      const res = await fetch(this.exportDxfUrlValue, {
        method:  "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf() },
        body:    JSON.stringify({ coords: this._verts.map(v => [v.x, v.y]), name: "Parcela" })
      })
      const blob = await res.blob()
      const url  = URL.createObjectURL(blob)
      Object.assign(document.createElement("a"), { href: url, download: "parcela.dxf" }).click()
      URL.revokeObjectURL(url)
    } catch (e) { this._setStatus("Eroare export DXF: " + e.message, "warn") }
  }

  showRaport() {
    if (this._verts.length < 3) { this._setStatus("Niciun poligon de raportat.", "warn"); return }
    const win = window.open("", "_blank")
    win.document.write(this._buildRaportHtml())
    win.document.close()
  }

  saveParcel() {
    if (this._verts.length < 3) { this._setStatus("Niciun poligon pentru salvare.", "warn"); return }
    this.wktFieldTarget.value      = this._buildWkt("MULTIPOLYGON")
    this.saveAreaFieldTarget.value = this._areaCalc > 0 ? this._areaCalc.toFixed(4) : ""
    this.saveFormTarget.submit()
  }

  saveBuilding() {
    if (this._verts.length < 3) { this._setStatus("Niciun poligon pentru salvare.", "warn"); return }
    this.wktFieldCladireTarget.value      = this._buildWkt("MULTIPOLYGON")
    this.saveAreaFieldCladireTarget.value = this._areaCalc > 0 ? this._areaCalc.toFixed(4) : ""
    this.saveFormCladireTarget.submit()
  }

  switchToParcel() {
    this._entityType = "parcela"
    this.formParcelaTarget.style.display = ""
    this.formCladireTarget.style.display = "none"
    this.btnEntityParcelaTarget.classList.add("digi-entity-btn--active")
    this.btnEntityCladireTarget.classList.remove("digi-entity-btn--active")
  }

  switchToBuilding() {
    this._entityType = "cladire"
    this.formParcelaTarget.style.display = "none"
    this.formCladireTarget.style.display = ""
    this.btnEntityCladireTarget.classList.add("digi-entity-btn--active")
    this.btnEntityParcelaTarget.classList.remove("digi-entity-btn--active")
  }

  // ── Snap multi-mode ──────────────────────────────────────────────────────

  _refreshSnap() {
    if (!this.map) return
    if (this._snap) this.map.removeInteraction(this._snap)
    const features = this._buildSnapFeatures()
    this._snap = new ol.interaction.Snap({
      features:       new ol.Collection(features),
      pixelTolerance: this.snapToleranceValue,
      vertex:         this._snapModes.has("endpoint") || this._snapModes.has("midpoint") || this._snapModes.has("centroid"),
      edge:           this._snapModes.has("nearest")
    })
    this._snap.setActive(this._snapEnabled)
    this.map.addInteraction(this._snap)
  }

  _buildSnapFeatures() {
    if (!this._hartaMap) return []
    const out  = []
    const refs = [this._hartaMap.parcelLayer, this._hartaMap.cgxmlLayer, this._hartaMap.cladiriLayer]
    const m    = this._snapModes
    refs.forEach(layer => {
      layer.getSource().getFeatures().forEach(f => {
        if (m.has("endpoint") || m.has("nearest")) out.push(f)
        if (m.has("midpoint")) this._addMidpoints(f, out)
        if (m.has("centroid")) this._addCentroid(f, out)
      })
    })
    return out
  }

  _addMidpoints(feature, out) {
    const geom = feature.getGeometry()
    if (!geom) return
    const t = geom.getType()
    const rings = t === "Polygon"      ? geom.getCoordinates()
                : t === "MultiPolygon" ? geom.getCoordinates().flat()
                : []
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

  // ── Linia de comandă (parser absolut / relativ / polar) ──────────────────

  _parseCmd(raw) {
    if (raw.startsWith("@")) {
      if (this._verts.length === 0) return null
      const last = this._verts[this._verts.length - 1]
      const rest = raw.slice(1)
      if (rest.includes("<")) {
        // Polar: lungime<unghi (grade, 0=N, 90=E, sens orar)
        const [lenS, angS] = rest.split("<")
        const len = parseFloat(lenS), ang = parseFloat(angS)
        if (isNaN(len) || isNaN(ang)) return null
        const rad = ang * Math.PI / 180
        return { x: last.x + len * Math.sin(rad), y: last.y + len * Math.cos(rad) }
      } else {
        const [dxS, dyS] = rest.replace(/,/g, " ").split(/\s+/)
        const dx = parseFloat(dxS), dy = parseFloat(dyS)
        if (isNaN(dx) || isNaN(dy)) return null
        return { x: last.x + dx, y: last.y + dy }
      }
    } else {
      const parts = raw.replace(/,/g, " ").split(/\s+/).filter(Boolean)
      if (parts.length < 2) return null
      const x = parseFloat(parts[0]), y = parseFloat(parts[1])
      if (isNaN(x) || isNaN(y)) return null
      return { x, y }
    }
  }

  // ── Ortho mode (constrânge desenul la 90°) ───────────────────────────────

  // Pentru type 'Polygon', OL trimite `coordinates = [openRing]` unde openRing
  // este array de [x, y] (vertecși confirmați + cursor). Funcția implicită
  // închide ring-ul prin append la primul vertex.
  _buildGeometryFunction() {
    return (coordinates, geometry) => {
      let ring = coordinates[0]
      if (this._orthoEnabled && ring.length >= 2) {
        const last = ring[ring.length - 1]
        const prev = ring[ring.length - 2]
        const dx = Math.abs(last[0] - prev[0])
        const dy = Math.abs(last[1] - prev[1])
        const fixed = dx > dy ? [last[0], prev[1]] : [prev[0], last[1]]
        ring = [...ring.slice(0, -1), fixed]
      }
      // Închide ring-ul (append primul vertex la final)
      const closed = ring.length > 0 ? [...ring, ring[0]] : ring
      if (!geometry) geometry = new ol.geom.Polygon([closed])
      else geometry.setCoordinates([closed])
      return geometry
    }
  }

  // ── Map handlers ─────────────────────────────────────────────────────────

  _onPointerMove(evt) {
    const [x, y] = ol.proj.transform(evt.coordinate, "EPSG:3857", "EPSG:3844")
    if (this.hasStatusXTarget) this.statusXTarget.textContent = FMT(x)
    if (this.hasStatusYTarget) this.statusYTarget.textContent = FMT(y)
  }

  _updateScale() {
    if (!this.map || !this.hasStatusScaleTarget) return
    const view = this.map.getView()
    const res  = view.getResolution()
    const mpu  = view.getProjection().getMetersPerUnit() || 1
    // Ecran: 96 dpi → 39.37 inch/m
    const scale = res * mpu * 39.37 * 96
    this.statusScaleTarget.textContent = scale > 1000 ? Math.round(scale / 100) * 100 : Math.round(scale)
  }

  _onDrawStart(evt) {
    this._currentFeature = evt.feature
    this._geomChangeKey  = this._currentFeature.getGeometry().on("change", (e) => {
      this._extractVerts(e.target)
      if (this._verts.length >= 3) {
        clearTimeout(this._areaDebounce)
        this._areaDebounce = setTimeout(() => this._calcArea(), 400)
      }
    })
  }

  _onDrawEnd(_evt) {
    if (this._geomChangeKey) ol.Observable.unByKey(this._geomChangeKey)
    if (this._draw && this.map) { this.map.removeInteraction(this._draw); this._draw = null }
    if (this._snap && this.map) { this.map.removeInteraction(this._snap); this._snap = null }
    this._hartaMap?.setDigitizing(false)
    this.btnCloseTarget.disabled = true
    this.btnStartTarget.classList.remove("btn-active")
    this._setStatus(`Poligon închis — ${this._verts.length} vertecși.`, "ok")
    this._calcArea()
    this._locateUat()
  }

  _extractVerts(geom) {
    const ring = geom.getCoordinates()[0] || []
    const verts = ring.length > 1 ? ring.slice(0, -1) : ring
    this._verts = verts.map((c) => {
      const [x, y] = ol.proj.transform(c, "EPSG:3857", "EPSG:3844")
      return { x, y }
    })
    this._updateVertexList()
    this._updateLiveArea()
  }

  _updateLiveArea() {
    if (!this.hasStatusAreaTarget) return
    if (this._verts.length < 3) { this.statusAreaTarget.textContent = "—"; return }
    // Calcul aproximativ Stereo70 (proiecție conformă pe România → suficient pentru live preview)
    const ring = [...this._verts.map(v => [v.x, v.y]), [this._verts[0].x, this._verts[0].y]]
    let area = 0
    for (let i = 0; i < ring.length - 1; i++) {
      area += ring[i][0] * ring[i + 1][1] - ring[i + 1][0] * ring[i][1]
    }
    area = Math.abs(area) / 2
    this.statusAreaTarget.textContent = `${FMT2(area)} mp`
  }

  _drawStyle(feature) {
    const type = feature.getGeometry()?.getType()
    // OL Draw creează intern 3 features: Polygon (constrâns prin geometryFunction),
    // LineString preview de la ultimul vertex la cursor (RAW, neconstrâns), și
    // Point la cursor. În modul ortho, ascundem LineString-ul ca să nu se vadă
    // o a doua linie pe direcția liberă a cursorului.
    if (this._orthoEnabled && type === "LineString") return null

    return new ol.style.Style({
      stroke: new ol.style.Stroke({ color: "#1d4ed8", width: 2 }),
      fill:   new ol.style.Fill({ color: "rgba(147, 197, 253, 0.25)" }),
      image:  new ol.style.Circle({
        radius: 4,
        fill:   new ol.style.Fill({ color: "#1d4ed8" }),
        stroke: new ol.style.Stroke({ color: "#fff", width: 2 })
      })
    })
  }

  // ── Locate UAT ───────────────────────────────────────────────────────────

  async _locateUat() {
    if (!this.locateUatUrlValue || this._verts.length < 3) return
    try {
      const res = await fetch(this.locateUatUrlValue, {
        method:  "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf() },
        body:    JSON.stringify({ coords: this._verts.map(v => [v.x, v.y]) })
      })
      const data = await res.json()
      if (!data.judet) return
      this.element.querySelectorAll('[data-siruta-target="judetInput"]').forEach(el => this._flashFill(el, data.judet))
      this.element.querySelectorAll('[data-siruta-target="localitateInput"]').forEach(el => this._flashFill(el, data.localitate))
    } catch (e) { console.warn("Locate UAT error:", e) }
  }

  _flashFill(input, value) {
    input.value = value
    input.classList.add("digi-autofill")
    setTimeout(() => input.classList.remove("digi-autofill"), 1800)
  }

  // ── Vertex list UI ───────────────────────────────────────────────────────

  _updateVertexList() {
    if (this.hasVertexTbodyTarget) {
      const tbody = this.vertexTbodyTarget
      tbody.innerHTML = ""
      this._verts.forEach((v, i) => {
        const tr = document.createElement("tr")
        tr.innerHTML = `<td class="vt-no">${i + 1}</td><td class="vt-coord">${FMT(v.x)}</td><td class="vt-coord">${FMT(v.y)}</td><td></td>`
        tbody.appendChild(tr)
      })
    }
    if (this.hasVertexCountTarget) this.vertexCountTarget.textContent = this._verts.length
  }

  // ── Area calc + diferență ────────────────────────────────────────────────

  async _calcArea() {
    if (this._verts.length < 3) return
    try {
      const res = await fetch(this.calcUrlValue, {
        method:  "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf() },
        body:    JSON.stringify({ coords: this._verts.map(v => [v.x, v.y]) })
      })
      const data = await res.json()
      this._areaCalc = data.suprafata || 0
      this.areaCalcTarget.textContent = this._areaCalc > 0 ? `${FMT2(this._areaCalc)} mp` : "—"
      const msgs = []
      if (data.is_valid  === false) msgs.push("⚠ Poligon invalid (auto-intersecție)")
      if (data.is_simple === false) msgs.push("⚠ Poligon non-simplu")
      this.topologyMsgTarget.innerHTML = msgs.map(m => `<span class="topo-warn">${m}</span>`).join("")
      this._updateDiffDisplay()
    } catch (e) { console.warn("Eroare calcul suprafață:", e) }
  }

  _updateDiffDisplay() {
    const act  = parseFloat(this.areaActTarget.value)
    const calc = this._areaCalc
    if (!act || !calc) { this.areaDiffTarget.textContent = "—"; this.areaDiffTarget.className = "digi-area-diff"; return }
    const pct  = ((calc - act) / act) * 100
    const sign = pct >= 0 ? "▲ +" : "▼ "
    this.areaDiffTarget.textContent = `${sign}${Math.abs(pct).toFixed(2)}%`
    this.areaDiffTarget.className   = `digi-area-diff ${Math.abs(pct) <= 3 ? "diff-ok" : Math.abs(pct) <= 10 ? "diff-warn" : "diff-bad"}`
  }

  // ── TXT import parsing ───────────────────────────────────────────────────

  _parseTxt(content) {
    const results = []
    content.trim().split(/\r?\n/).forEach(line => {
      const raw = line.trim()
      if (!raw || raw.startsWith("#") || raw.startsWith("//")) return
      const parts = raw.replace(/,/g, ".").split(/[\s;]+/).filter(Boolean)
      let x, y
      if (parts.length >= 3) { x = parseFloat(parts[1]); y = parseFloat(parts[2]) }
      else if (parts.length === 2) { x = parseFloat(parts[0]); y = parseFloat(parts[1]) }
      if (!isNaN(x) && !isNaN(y)) results.push({ x, y })
    })
    return results
  }

  // ── WKT / Raport ─────────────────────────────────────────────────────────

  _buildWkt(type = "POLYGON") {
    if (this._verts.length < 3) return ""
    const pts = [...this._verts, this._verts[0]]
    const ring = pts.map(v => `${v.x.toFixed(4)} ${v.y.toFixed(4)}`).join(", ")
    return type === "MULTIPOLYGON" ? `MULTIPOLYGON(((${ring})))` : `POLYGON((${ring}))`
  }

  _buildRaportHtml() {
    const rows = this._verts.map((v, i) =>
      `<tr><td>${i + 1}</td><td>${FMT(v.x)}</td><td>${FMT(v.y)}</td></tr>`
    ).join("")
    const act  = parseFloat(this.areaActTarget.value) || 0
    const calc = this._areaCalc
    const pct  = act ? (((calc - act) / act) * 100).toFixed(2) : "—"
    return `<!DOCTYPE html><html lang="ro"><head>
      <meta charset="UTF-8"><title>Raport Digitizare</title>
      <style>
        body{font-family:Arial,sans-serif;max-width:800px;margin:30px auto;font-size:13px}
        h1{font-size:18px;border-bottom:2px solid #1d4ed8;padding-bottom:6px}
        h2{font-size:13px;margin-top:20px;color:#6b7280;text-transform:uppercase}
        table{width:100%;border-collapse:collapse;margin-top:8px}
        th{background:#f3f4f6;padding:6px 10px;text-align:left;font-size:12px}
        td{padding:5px 10px;border-bottom:1px solid #e5e7eb;font-family:monospace}
      </style></head><body>
      <h1>Raport Digitizare Parcelă Cadastrală</h1>
      <p>Generat: ${new Date().toLocaleString("ro-RO")} | Proiecție: Stereo 70 (EPSG:3844)</p>
      <h2>Coordonate vertecși</h2>
      <table><thead><tr><th>#</th><th>X — Est (m)</th><th>Y — Nord (m)</th></tr></thead><tbody>${rows}</tbody></table>
      <h2>Suprafețe</h2>
      <p>Calculată (PostGIS): <b>${FMT2(calc)} mp</b> | Din act: <b>${act ? FMT2(act) + " mp" : "—"}</b> | Diferență: <b>${pct !== "—" ? (parseFloat(pct) >= 0 ? "+" : "") + pct + "%" : "—"}</b></p>
      <h2>WKT (Stereo 70)</h2>
      <pre style="font-size:10px;background:#f8fafc;padding:10px;overflow:auto;word-break:break-all">${this._buildWkt()}</pre>
    </body></html>`
  }

  // ── Keyboard shortcuts ───────────────────────────────────────────────────

  _handleGlobalKey(evt) {
    const tag = evt.target.tagName
    if (tag === "INPUT" || tag === "TEXTAREA") return
    if (evt.key === "F3") { evt.preventDefault(); this.toggleSnap() }
    if (evt.key === "F8") { evt.preventDefault(); this.toggleOrtho() }
    if (evt.key === "Escape" && this._draw) { evt.preventDefault(); this.clearAll() }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  _setStatus(msg, type = "info") {
    this.statusBarTarget.textContent = msg
    this.statusBarTarget.className   = `digi-status digi-status-${type}`
  }

  _csrf() { return document.querySelector('[name="csrf-token"]')?.content ?? "" }
}
