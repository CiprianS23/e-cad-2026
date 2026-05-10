import { Controller } from "@hotwired/stimulus"

const FMT  = (n) => Number(n).toLocaleString("ro-RO", { minimumFractionDigits: 3, maximumFractionDigits: 3 })
const FMT2 = (n) => Number(n).toLocaleString("ro-RO", { minimumFractionDigits: 2, maximumFractionDigits: 2 })

export default class extends Controller {
  static outlets = ["harta-map"]

  static values = {
    calcUrl:       String,
    verificaUrl:   String,
    exportDxfUrl:  String,
    locateUatUrl:  String,
    snapTolerance: { type: Number, default: 15 },
    editKind:      String,
    editId:        String,
    saveBatchUrl:  String
  }

  static targets = [
    "panel", "panelBody", "editTopoMirror",
    "snapSlider", "snapToleranceVal", "snapModes",
    "btnStart", "btnEdit", "btnDelete", "btnClose", "btnUndo", "btnAudit", "auditList",
    "dxfFileInput", "dxfMapping",
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
    this._verts             = []
    this._areaCalc          = 0
    this._areaDebounce      = null
    this._topoDebounce      = null
    this._entityType        = "parcela"
    this._snapEnabled       = true
    this._orthoEnabled      = false
    this._snapModes         = new Set(["endpoint", "midpoint"])
    this._polygonValid      = false
    this._polygonSimple     = false
    this._topologyIssues    = []
    this._topologyHasErrors = false

    this._drawSource = new ol.source.Vector()
    this._drawLayer  = new ol.layer.Vector({
      source: this._drawSource,
      style:  this._drawStyle.bind(this),
      properties: { name: "digitizare" }
    })

    // Layer separat pentru evidențierea conflictelor topologice (overlap, sliver, vertex-off)
    this._topoSource = new ol.source.Vector()
    this._topoLayer  = new ol.layer.Vector({
      source: this._topoSource,
      style:  this._topoStyle.bind(this),
      properties: { name: "topologie-issues" },
      zIndex: 1000
    })

    // Layer dedicat pentru audit topologic global — geometriile issue-urilor
    // de pe întreaga hartă (overlap-uri, clădiri multi-parcela, etc.)
    this._auditSource = new ol.source.Vector()
    this._auditLayer  = new ol.layer.Vector({
      source: this._auditSource,
      style:  (feat) => {
        const sev = feat.get("severity") || "error"
        return new ol.style.Style({
          stroke: new ol.style.Stroke({
            color: sev === "error" ? "#dc2626" : "#d97706",
            width: 3,
            lineDash: sev === "warning" ? [6, 3] : null
          }),
          fill: new ol.style.Fill({
            color: sev === "error" ? "rgba(220, 38, 38, 0.35)" : "rgba(217, 119, 6, 0.25)"
          })
        })
      },
      properties: { name: "audit-topologie" },
      zIndex: 1050
    })

    // Layer cu cerculețe la fiecare vertex (vizibile pentru a identifica
    // vertecșii coliniari care altfel nu se văd).
    // - Roșu (#dc2626): vertecși ai poligonului propriu (digitizare sau edit primar)
    // - Portocaliu (#f59e0b): vertecși ai vecinilor editabili (în edit mode topology-aware)
    this._editVertexSource = new ol.source.Vector()
    this._editVertexLayer  = new ol.layer.Vector({
      source: this._editVertexSource,
      style:  (feat) => new ol.style.Style({
        image: new ol.style.Circle({
          radius: feat.get("neighborVertex") ? 4 : 5,
          fill:   new ol.style.Fill({ color: feat.get("neighborVertex") ? "#f59e0b" : "#dc2626" }),
          stroke: new ol.style.Stroke({ color: "#fff", width: 2 })
        })
      }),
      properties: { name: "edit-vertices" },
      zIndex: 1100
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
    // Ascultăm evenimentele de selecție feature de la harta-map
    outlet.element.addEventListener("harta-map:feature-selected",   (e) => this._onFeatureSelected(e.detail))
    outlet.element.addEventListener("harta-map:feature-deselected", ()  => this._onFeatureSelected(null))
  }

  hartaMapOutletDisconnected() { this._teardown() }

  _attachToMap() {
    this.map = this._hartaMap?.map
    if (!this.map) return
    this.map.addLayer(this._drawLayer)
    this.map.addLayer(this._topoLayer)
    this.map.addLayer(this._editVertexLayer)  // cerculețele roșii la vertecși — pentru ambele moduri
    this.map.addLayer(this._auditLayer)       // layer audit topologic global
    this._mouseMoveKey = this.map.on("pointermove", (evt) => this._onPointerMove(evt))
    this._moveEndKey   = this.map.on("moveend",     ()    => this._updateScale())
    this._updateScale()
    this._updateSaveAvailability()  // butoanele Salvează încep dezactivate

    // Dacă URL-ul indică editare (?edit_kind=parcela&edit_id=5), intrăm în mod editare
    if (this.editKindValue && this.editIdValue) {
      this._waitForFeatureAndEdit()
    }
  }

  _teardown() {
    if (this._mouseMoveKey) ol.Observable.unByKey(this._mouseMoveKey)
    if (this._moveEndKey)   ol.Observable.unByKey(this._moveEndKey)
    if (this._draw && this.map) this.map.removeInteraction(this._draw)
    if (this._snap && this.map) this.map.removeInteraction(this._snap)
    if (this._drawLayer && this.map) this.map.removeLayer(this._drawLayer)
    if (this._topoLayer && this.map) this.map.removeLayer(this._topoLayer)
    if (this._editVertexLayer && this.map) this.map.removeLayer(this._editVertexLayer)
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

    const isDistance   = /^-?\d+(\.\d+)?$/.test(raw)
    const isRelOrPolar = raw.startsWith("@")
    const isAbsolute   = !isDistance && !isRelOrPolar

    // Pornește digitizarea automat doar pentru coords absolute (au sens fără
    // punct anterior). Pentru distanță / relativ / polar, cere punct prim.
    if (!this._draw) {
      if (!isAbsolute) {
        this._cmdHint(`Eroare: ${raw} cere un punct anterior. Începe cu coords absolute (X,Y).`, true)
        return
      }
      this.startDrawing()
    }

    if (isDistance && this._verts.length === 0) {
      this._cmdHint(`Distanță fără punct anterior. Adaugă X,Y sau click pe hartă mai întâi.`, true)
      return
    }

    if (isDistance && !this._cursorStereo) {
      this._cmdHint(`Mișcă mouse-ul pe hartă pentru a stabili direcția înainte de a tasta lungimea.`, true)
      return
    }

    if (isDistance && this._cursorStereo && this._verts.length > 0) {
      const last = this._verts[this._verts.length - 1]
      const dx = this._cursorStereo.x - last.x
      const dy = this._cursorStereo.y - last.y
      if (Math.abs(dx) < 0.001 && Math.abs(dy) < 0.001) {
        this._cmdHint(`Mișcă mouse-ul departe de ultimul vertex pentru a stabili direcția, apoi reintroduce lungimea.`, true)
        return
      }
    }

    const pt = this._parseCmd(raw)
    if (!pt) {
      this._cmdHint(`Format invalid: ${raw}  (acceptat: X,Y · doar număr · @ΔX,ΔY · @len<deg; punctul zecimal cu .)`, true)
      return
    }

    const mapCoord = [pt.x, pt.y]  // direct în Stereo 70 (view e EPSG:3844)
    try {
      this._draw.appendCoordinates([mapCoord])
      const view = this.map.getView()
      if (!ol.extent.containsCoordinate(view.calculateExtent(this.map.getSize()), mapCoord)) {
        view.animate({ center: mapCoord, zoom: Math.max(view.getZoom() || 0, 6), duration: 250 })
      }
      this._cmdHint(`✓ Punct: X=${FMT(pt.x)}  Y=${FMT(pt.y)}`, false)
    } catch (e) {
      this._cmdHint(`Eroare appendCoordinates: ${e.message}`, true)
    }
  }

  _cmdHint(msg, isError) {
    if (!this.hasCmdHintTarget) return
    this.cmdHintTarget.textContent = msg
    this.cmdHintTarget.style.color = isError ? "#ef4444" : "#22c55e"
    clearTimeout(this._cmdHintTimer)
    this._cmdHintTimer = setTimeout(() => {
      this.cmdHintTarget.textContent = "Stereo70 (EPSG:3844)"
      this.cmdHintTarget.style.color = ""
    }, 3500)
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
    this._polygonValid = false
    this._polygonSimple = false
    this._topologyIssues = []
    this._topologyHasErrors = false
    if (this._draw && this.map) { this.map.removeInteraction(this._draw); this._draw = null }
    if (this._snap && this.map) { this.map.removeInteraction(this._snap); this._snap = null }
    this._hartaMap?.setDigitizing(false)
    this._drawSource.clear()
    this._topoSource?.clear()
    this._editVertexSource?.clear()
    this.btnStartTarget.classList.remove("btn-active")
    this.btnCloseTarget.disabled = true
    this.btnUndoTarget.disabled  = true
    this._updateSaveAvailability()
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
    this._draw.appendCoordinates([[x, y]])  // direct în Stereo 70
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
      this._draw.appendCoordinates(pts.map(({ x, y }) => [x, y]))  // direct în Stereo 70
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

  async saveParcel() {
    if (!await this._validateBeforeSave()) return
    this.wktFieldTarget.value      = this._buildWkt("MULTIPOLYGON")
    this.saveAreaFieldTarget.value = this._areaCalc > 0 ? this._areaCalc.toFixed(4) : ""
    this.saveFormTarget.submit()
  }

  async saveBuilding() {
    if (!await this._validateBeforeSave()) return
    this.wktFieldCladireTarget.value      = this._buildWkt("MULTIPOLYGON")
    this.saveAreaFieldCladireTarget.value = this._areaCalc > 0 ? this._areaCalc.toFixed(4) : ""
    this.saveFormCladireTarget.submit()
  }

  // Forțează o validare sincronă proaspătă înainte să accepte save (anti-race)
  async _validateBeforeSave() {
    if (this._verts.length < 3) {
      this._setStatus("Niciun poligon pentru salvare (minim 3 vertecși).", "warn")
      return false
    }
    clearTimeout(this._areaDebounce)
    clearTimeout(this._topoDebounce)
    this._setStatus("Verificare topologie…")
    await this._calcArea()
    await this._verifyTopology()
    return this._guardSavable()
  }

  _guardSavable() {
    if (this._verts.length < 3) {
      this._setStatus("Niciun poligon pentru salvare (minim 3 vertecși).", "warn")
      return false
    }
    if (!this._polygonValid) {
      this._setStatus("Poligon INVALID (auto-intersecție / topologie eronată) — corectează vertecșii înainte de salvare.", "warn")
      return false
    }
    if (!this._polygonSimple) {
      this._setStatus("Poligon NON-SIMPLU — corectează vertecșii înainte de salvare.", "warn")
      return false
    }
    if (this._topologyHasErrors) {
      const errs = this._topologyIssues.filter(i => i.severity === "error")
      this._setStatus(`Conflict topologic: ${errs.length} eroare(i) cu vecinii — vezi panoul.`, "warn")
      return false
    }
    return true
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
        // Includem TOATE features-urile (primary + vecini) ca ținte de snap.
        // Astfel snap-ul funcționează simetric: drag de la primary spre vecin
        // ȘI invers. Risc de self-snap (V1 spre V2 al aceluiași poligon) e
        // minor — utilizatorul poate evita prin precizie sau Undo.
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
    // Direct distance entry (CAD): doar număr → folosește direcția cursorului
    if (/^-?\d+(\.\d+)?$/.test(raw)) {
      const dist = parseFloat(raw)
      if (isNaN(dist) || this._verts.length === 0 || !this._cursorStereo) return null
      const last = this._verts[this._verts.length - 1]
      let dx = this._cursorStereo.x - last.x
      let dy = this._cursorStereo.y - last.y
      if (this._orthoEnabled) {
        if (Math.abs(dx) > Math.abs(dy)) dy = 0
        else dx = 0
      }
      const len = Math.sqrt(dx * dx + dy * dy)
      if (len === 0) return null
      return { x: last.x + dist * dx / len, y: last.y + dist * dy / len }
    }

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
    // View-ul OL e în EPSG:3844 → evt.coordinate e DIRECT în Stereo 70 (m), fără transform.
    const [x, y] = evt.coordinate
    this._cursorStereo = { x, y }
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
    // Extragem vertecșii inițiali — OL a creat deja geometria înainte de drawstart,
    // deci listener-ul de „change" nu vede primul vertex (ar pierde populația _verts)
    this._extractVerts(this._currentFeature.getGeometry())
    this._geomChangeKey = this._currentFeature.getGeometry().on("change", (e) => {
      this._extractVerts(e.target)
      if (this._verts.length >= 3) {
        clearTimeout(this._areaDebounce)
        this._areaDebounce = setTimeout(() => this._calcArea(), 400)
        clearTimeout(this._topoDebounce)
        this._topoDebounce = setTimeout(() => this._verifyTopology(), 700)
      }
    })
  }

  _onDrawEnd(evt) {
    if (this._geomChangeKey) ol.Observable.unByKey(this._geomChangeKey)

    // Re-extragem _verts din geometria FINALĂ (închisă, fără cursor live).
    // OL.finishDrawing pop-uiește cursor-ul ÎNAINTE să închidă ring-ul, dar
    // ultima dată când change event a fost prins în handler-ul nostru, _draw
    // era încă activ → _extractVerts elimina și ultimul vertex real ca pe cursor.
    const ring = evt.feature.getGeometry().getCoordinates()[0] || []
    this._verts = (ring.length > 1 ? ring.slice(0, -1) : ring).map(c => ({ x: c[0], y: c[1] }))
    this._polygonValid      = false
    this._polygonSimple     = false
    this._topologyHasErrors = true
    this._renderEditVertices()
    this._updateVertexList()
    this._updateLiveArea()
    this._updateSaveAvailability()

    if (this._draw && this.map) { this.map.removeInteraction(this._draw); this._draw = null }
    if (this._snap && this.map) { this.map.removeInteraction(this._snap); this._snap = null }
    this._hartaMap?.setDigitizing(false)
    this.btnCloseTarget.disabled = true
    this.btnStartTarget.classList.remove("btn-active")
    this._setStatus(`Poligon închis — ${this._verts.length} vertecși.`, "ok")
    this._calcArea()
    this._verifyTopology()
    this._locateUat()
  }

  _extractVerts(geom) {
    // Suport pentru ambele tipuri de geometrii:
    // - Polygon (la digitizare nouă):   getCoordinates() = [ring, hole?...]
    // - MultiPolygon (la edit din DB):  getCoordinates() = [[ring, hole?...], [...], ...]
    const type = geom.getType()
    let ring = []
    if (type === "MultiPolygon") {
      ring = geom.getCoordinates()[0]?.[0] || []
    } else if (type === "Polygon") {
      ring = geom.getCoordinates()[0] || []
    }
    // Format ring în timpul desenării: [v1, v2, ..., vN, cursor, v1]
    // Format după finishDrawing / din DB: [v1, v2, ..., vN, v1]
    // Eliminăm întotdeauna ultimul (closing duplicate); dacă desenarea e activă
    // mai eliminăm încă unul (cursor live) ca să rămână doar vertecșii confirmați.
    let actual = ring.length > 1 ? ring.slice(0, -1) : ring
    if (this._draw && actual.length > 1) actual = actual.slice(0, -1)

    // Coords ring sunt deja în EPSG:3844 (view-ul e în Stereo 70), zero round-trip.
    this._verts = actual.map((c) => ({ x: c[0], y: c[1] }))
    // Pesimist: fiecare modificare geometrică invalidează rezultatul anterior
    // de validare. _calcArea + _verifyTopology vor seta valorile la răspunsul PostGIS.
    this._polygonValid      = false
    this._polygonSimple     = false
    this._topologyHasErrors = true
    this._updateSaveAvailability()
    this._updateVertexList()
    this._updateLiveArea()
    this._renderEditVertices()  // cerculețe roșii la vertecșii confirmați (ambele moduri)
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
      this._areaCalc      = data.suprafata || 0
      this._polygonValid  = data.is_valid  !== false
      this._polygonSimple = data.is_simple !== false
      this.areaCalcTarget.textContent = this._areaCalc > 0 ? `${FMT2(this._areaCalc)} mp` : "—"
      const msgs = []
      if (data.is_valid  === false) msgs.push("⚠ Poligon invalid (auto-intersecție)")
      if (data.is_simple === false) msgs.push("⚠ Poligon non-simplu")
      this.topologyMsgTarget.innerHTML = msgs.map(m => `<span class="topo-warn">${m}</span>`).join("")
      this._updateSaveAvailability()
      this._updateDiffDisplay()
    } catch (e) { console.warn("Eroare calcul suprafață:", e) }
  }

  _isPolygonSavable() {
    return this._verts.length >= 3
      && this._polygonValid
      && this._polygonSimple
      && !this._topologyHasErrors
  }

  // ── Verificare topologie cu vecini (overlap, sliver, vertex-on-vertex) ──

  async _verifyTopology() {
    if (!this.hasVerificaUrlValue || this._verts.length < 3) return
    try {
      const res = await fetch(this.verificaUrlValue, {
        method:  "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf() },
        body:    JSON.stringify(this._verifyTopologyParams())
      })
      const data = await res.json()
      this._topologyIssues    = data.issues || []
      this._topologyHasErrors = !!data.has_errors
      this._renderTopologyIssues()
      this._updateSaveAvailability()
    } catch (e) {
      console.warn("Topology check error:", e)
    }
  }

  _renderTopologyIssues() {
    this._topoSource.clear()
    const fmt = new ol.format.GeoJSON()
    this._topologyIssues.forEach(issue => {
      if (!issue.geojson) return
      try {
        const feat = fmt.readFeature(issue.geojson, {
          dataProjection:    "EPSG:3844",
          featureProjection: "EPSG:3844"
        })
        feat.set("severity", issue.severity)
        feat.set("issueType", issue.type)
        feat.set("message",  issue.message)
        this._topoSource.addFeature(feat)
      } catch (e) { /* skip un-parsable */ }
    })
    this._renderTopologyPanel()
  }

  _renderTopologyPanel() {
    const errs  = this._topologyIssues.filter(i => i.severity === "error")
    const warns = this._topologyIssues.filter(i => i.severity === "warning")
    const html  = []
    if (errs.length === 0 && warns.length === 0) {
      // Show "OK" message when no issues
      if (this._verts.length >= 3) {
        html.push(`<span class="topo-ok">✓ Topologie OK (fără conflicte cu vecini)</span>`)
      }
    } else {
      if (errs.length)  html.push(`<div class="topo-error-header">⛔ ${errs.length} eroare(i):</div>`)
      errs.forEach(e  => html.push(`<span class="topo-warn topo-error-item">• ${e.message}</span>`))
      if (warns.length) html.push(`<div class="topo-warn-header">⚠ ${warns.length} avertizare(i):</div>`)
      warns.forEach(w => html.push(`<span class="topo-warn">• ${w.message}</span>`))
    }
    const out = html.join("")
    this.topologyMsgTarget.innerHTML = out
    // Mirror în panoul de edit (vizibil la top)
    if (this.hasEditTopoMirrorTarget) this.editTopoMirrorTarget.innerHTML = out
  }

  _topoStyle(feature) {
    const sev  = feature.get("severity")
    const type = feature.get("issueType")
    if (sev === "error") {
      // Overlap rosu pulsant + bordura groasă
      return new ol.style.Style({
        stroke: new ol.style.Stroke({ color: "#dc2626", width: 3 }),
        fill:   new ol.style.Fill({ color: "rgba(220, 38, 38, 0.45)" })
      })
    }
    if (type === "vertex_off") {
      // Vertex NOU pe muchia vecinului — portocaliu (problema noului poligon)
      return new ol.style.Style({
        image: new ol.style.Circle({
          radius: 7,
          fill:   new ol.style.Fill({ color: "#d97706" }),
          stroke: new ol.style.Stroke({ color: "#fff", width: 2 })
        })
      })
    }
    if (type === "neighbor_vertex_off") {
      // Vertex VECIN pe muchia ta — albastru (trebuie adăugat ca vertex propriu)
      return new ol.style.Style({
        image: new ol.style.Circle({
          radius: 7,
          fill:   new ol.style.Fill({ color: "#2563eb" }),
          stroke: new ol.style.Stroke({ color: "#fff", width: 2 })
        })
      })
    }
    // sliver / alte warnings
    return new ol.style.Style({
      stroke: new ol.style.Stroke({ color: "#d97706", width: 2, lineDash: [4, 4] }),
      fill:   new ol.style.Fill({ color: "rgba(251, 191, 36, 0.25)" })
    })
  }

  _updateSaveAvailability() {
    const ok = this._isPolygonSavable()
    this.element.querySelectorAll('[data-action*="digitizare#saveParcel"], [data-action*="digitizare#saveBuilding"]')
      .forEach(btn => {
        btn.disabled = !ok
        btn.title = ok ? "" : "Poligon invalid topologic — nu se poate salva"
      })
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
    // 6 decimale = precizie µm în metri Stereo70 — elimină drift-ul de
    // rotunjire care cauza overlap micrometric la poligoane adiacente.
    const ring = pts.map(v => `${v.x.toFixed(6)} ${v.y.toFixed(6)}`).join(", ")
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

  // ── Import DXF ────────────────────────────────────────────────────────

  async onDxfFileSelected(evt) {
    const file = evt.target.files[0]
    if (!file) return
    if (typeof DxfParser === "undefined") {
      alert("dxf-parser nu e încărcat (verifică conexiunea sau reîncarcă pagina)")
      return
    }
    const url = evt.params?.url || "/digitizare/import_dxf"
    try {
      const text = await file.text()
      const parser = new DxfParser()
      const dxf = parser.parseSync(text)
      const layers = this._extractDxfPolygons(dxf)
      if (Object.keys(layers).length === 0) {
        this._renderDxfMapping(null, "Niciun poligon închis găsit în fișier (LWPOLYLINE/POLYLINE cu shape=true).")
        return
      }
      this._dxfLayers = layers
      this._dxfImportUrl = url
      this._renderDxfMapping(layers, file.name)
    } catch (e) {
      this._renderDxfMapping(null, `Eroare parsare DXF: ${e.message}`)
    } finally {
      evt.target.value = ""  // reset ca user să poată reîncărca același fișier
    }
  }

  _extractDxfPolygons(dxf) {
    const out = {}
    if (!dxf?.entities) return out
    dxf.entities.forEach(ent => {
      // LWPOLYLINE și POLYLINE pot fi închise (shape=true) sau deschise.
      // Pentru import, considerăm doar poligoanele închise.
      if (ent.type !== "LWPOLYLINE" && ent.type !== "POLYLINE") return
      const isClosed = ent.shape === true || ent.closed === true
      if (!isClosed) return
      const verts = (ent.vertices || []).filter(v => Number.isFinite(v.x) && Number.isFinite(v.y))
      if (verts.length < 3) return

      const layer = ent.layer || "0"
      if (!out[layer]) out[layer] = []
      out[layer].push(verts.map(v => [v.x, v.y]))
    })
    return out
  }

  _renderDxfMapping(layers, filenameOrError) {
    if (!this.hasDxfMappingTarget) return
    const root = this.dxfMappingTarget

    if (!layers) {
      root.style.display = "block"
      root.innerHTML = `<div class="topo-warn">${filenameOrError}</div>`
      return
    }

    // Alegere automată default mapping bazat pe nume layer
    const guess = (layerName) => {
      const n = layerName.toUpperCase()
      if (/PARC|TEREN|IMOBIL|LIM/.test(n))   return "parcela"
      if (/CLAD|CONST|BUILD/.test(n))         return "cladire"
      if (/SECT/.test(n))                     return "sector"
      return "ignora"
    }

    const rows = Object.entries(layers).map(([layer, polys]) => {
      const def = guess(layer)
      const opts = ["parcela", "cladire", "sector", "ignora"].map(c => {
        const labels = { parcela: "Parcele", cladire: "Clădiri", sector: "Sectoare", ignora: "Ignoră" }
        return `<option value="${c}" ${c === def ? "selected" : ""}>${labels[c]}</option>`
      }).join("")
      return `
        <tr>
          <td>${layer}</td>
          <td style="text-align:right">${polys.length}</td>
          <td>
            <select class="input input-sm dxf-cat" data-layer="${layer}">${opts}</select>
          </td>
        </tr>
      `
    }).join("")

    root.style.display = "block"
    root.innerHTML = `
      <div class="digi-dxf-header">📥 ${filenameOrError}</div>
      <table class="digi-dxf-table">
        <thead><tr><th>Layer DXF</th><th>Poligoane</th><th>Mapează la</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
      <div class="digi-dxf-defaults">
        <div class="digi-section-label" style="margin:8px 0 4px">Defaults pentru parcele</div>
        <div class="digi-save-grid">
          <select class="input input-sm" data-digitizare-target="dxfCategFolosinta">
            <option value="neproductiv" selected>Neproductiv</option>
            <option value="arabil">Arabil</option>
            <option value="pasune">Pășune</option>
            <option value="faneata">Fânețe</option>
            <option value="vie">Vie</option>
            <option value="livada">Livadă</option>
            <option value="padure">Pădure</option>
            <option value="curti_constructii">Curți/construcții</option>
            <option value="ape">Ape</option>
          </select>
          <input type="text" class="input input-sm" placeholder="Județ" data-digitizare-target="dxfJudet">
          <input type="text" class="input input-sm" placeholder="Localitate" data-digitizare-target="dxfLocalitate">
        </div>
      </div>
      <div class="digi-btn-row" style="margin-top:8px">
        <button type="button" class="btn btn-primary btn-sm" data-action="click->digitizare#submitDxfImport">
          ✓ Importă
        </button>
        <button type="button" class="btn btn-outline btn-sm" data-action="click->digitizare#cancelDxfImport">
          ✕ Anulează
        </button>
      </div>
      <div class="digi-dxf-result" data-digitizare-target="dxfResult"></div>
    `
  }

  cancelDxfImport() {
    if (!this.hasDxfMappingTarget) return
    this.dxfMappingTarget.style.display = "none"
    this.dxfMappingTarget.innerHTML = ""
    this._dxfLayers = null
  }

  async submitDxfImport() {
    if (!this._dxfLayers) return
    const items = []
    this.dxfMappingTarget.querySelectorAll(".dxf-cat").forEach(sel => {
      const layer = sel.dataset.layer
      const cat   = sel.value
      if (cat === "ignora") return
      const polys = this._dxfLayers[layer] || []
      polys.forEach((coords, idx) => {
        const wkt = this._coordsToWkt(coords)
        if (wkt) items.push({ category: cat, geom_wkt: wkt, source_layer: layer, source_idx: idx })
      })
    })
    if (items.length === 0) {
      alert("Niciun poligon nu e mapat la o categorie (toate sunt ignorate).")
      return
    }

    const defaults = {
      categoria_folosinta: this.element.querySelector('[data-digitizare-target="dxfCategFolosinta"]')?.value,
      judet:               this.element.querySelector('[data-digitizare-target="dxfJudet"]')?.value || "—",
      localitate:          this.element.querySelector('[data-digitizare-target="dxfLocalitate"]')?.value || "—"
    }

    const resultEl = this.element.querySelector('[data-digitizare-target="dxfResult"]')
    if (resultEl) resultEl.innerHTML = "⏳ Se importă..."

    try {
      const res = await fetch(this._dxfImportUrl || "/digitizare/import_dxf", {
        method:  "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this._csrf(),
          "Accept":       "application/json"
        },
        body: JSON.stringify({ items, defaults })
      })
      const data = await res.json()
      if (data.ok) {
        const r = data.results
        const msg = `✓ ${r.parcela.created} parcele + ${r.cladire.created} clădiri create`
                  + (r.parcela.errors.length || r.cladire.errors.length ? " (cu erori — vezi detalii)" : "")
        if (resultEl) {
          resultEl.innerHTML = `
            <div class="topo-ok">${msg}</div>
            ${r.parcela.errors.length ? `<div class="topo-warn"><b>Erori parcele:</b><br>${r.parcela.errors.join('<br>')}</div>` : ""}
            ${r.cladire.errors.length ? `<div class="topo-warn"><b>Erori clădiri:</b><br>${r.cladire.errors.join('<br>')}</div>` : ""}
          `
        }
        // Reload parcele și clădiri pe hartă
        this._hartaMap?._loadParcele()
        this._hartaMap?._loadCladiri()
      } else {
        if (resultEl) resultEl.innerHTML = `<div class="topo-warn">Eroare: ${data.error}</div>`
      }
    } catch (e) {
      if (resultEl) resultEl.innerHTML = `<div class="topo-warn">Eroare rețea: ${e.message}</div>`
    }
  }

  _coordsToWkt(coords) {
    if (!coords || coords.length < 3) return null
    const closed = (coords[0][0] !== coords[coords.length - 1][0] || coords[0][1] !== coords[coords.length - 1][1])
                   ? [...coords, coords[0]] : coords
    const ring = closed.map(c => `${c[0].toFixed(6)} ${c[1].toFixed(6)}`).join(", ")
    return `MULTIPOLYGON(((${ring})))`
  }

  // ── Audit topologie global ─────────────────────────────────────────────

  async runAuditTopologie(evt) {
    const url = evt?.params?.url || "/digitizare/audit_topologie"
    if (this.hasBtnAuditTarget) {
      this.btnAuditTarget.disabled = true
      this.btnAuditTarget.textContent = "🔄 Scanare…"
    }
    try {
      const res = await fetch(url, { headers: { "Accept": "application/json" } })
      const data = await res.json()
      this._renderAuditResults(data)
    } catch (e) {
      this._setStatus(`Eroare audit: ${e.message}`, "warn")
    } finally {
      if (this.hasBtnAuditTarget) {
        this.btnAuditTarget.disabled = false
        this.btnAuditTarget.textContent = "🔍 Scanează erori"
      }
    }
  }

  clearAudit() {
    this._auditSource?.clear()
    if (this.hasAuditListTarget) this.auditListTarget.innerHTML = ""
  }

  // Apelat din onclick inline pe items din lista audit
  zoomToAuditIssue(idx) {
    const features = this._auditSource?.getFeatures() || []
    const feat = features[idx]
    if (!feat || !this.map) return
    const ext = feat.getGeometry().getExtent()
    this.map.getView().fit(ext, { padding: [80, 80, 80, 80], maxZoom: 19, duration: 350 })
  }

  _renderAuditResults(data) {
    this._auditSource.clear()
    if (!this.hasAuditListTarget) return
    if (!data.issues || data.issues.length === 0) {
      this.auditListTarget.innerHTML = `<div class="topo-ok">✓ Niciuna erori topologice (${data.total || 0} verificate)</div>`
      return
    }

    // Add features to map source
    const fmt = new ol.format.GeoJSON()
    data.issues.forEach((issue, idx) => {
      if (!issue.geojson) return
      try {
        const feat = fmt.readFeature(issue.geojson, {
          dataProjection:    "EPSG:3844",
          featureProjection: "EPSG:3844"
        })
        feat.set("severity", issue.severity)
        feat.set("auditIdx",  idx)
        this._auditSource.addFeature(feat)
      } catch (e) { /* skip un-parseable */ }
    })

    // Render list grouped by category
    const byCat = {}
    data.issues.forEach((iss, idx) => {
      const cat = iss.category || "Altele"
      if (!byCat[cat]) byCat[cat] = []
      byCat[cat].push({ ...iss, _idx: idx })
    })

    const sections = Object.entries(byCat).map(([cat, items]) => {
      const itemsHtml = items.map(i => `
        <li class="digi-audit-item digi-audit-item--${i.severity || 'error'}">
          <button type="button" class="digi-audit-zoom-btn"
                  onclick="event.stopPropagation();
                           document.querySelector('[data-controller~=digitizare]').dispatchEvent(
                             new CustomEvent('audit-zoom', { detail: ${i._idx} }))">
            🔎
          </button>
          <span>${i.message}</span>
        </li>
      `).join("")
      return `
        <div class="digi-audit-category">
          <div class="digi-audit-category-header">${cat} <span class="badge badge-error">${items.length}</span></div>
          <ul class="digi-audit-items">${itemsHtml}</ul>
        </div>
      `
    }).join("")

    this.auditListTarget.innerHTML = `
      <div class="digi-audit-summary">
        <strong>${data.total} probleme</strong> în ${data.categories?.length || 0} categorii
      </div>
      ${sections}
    `

    // Listener pentru zoom (delegated)
    if (!this._auditZoomBound) {
      this.element.addEventListener("audit-zoom", (e) => this.zoomToAuditIssue(e.detail))
      this._auditZoomBound = true
    }
  }

  // ── Selecție feature (pentru intrare în edit mode) ────────────────────────

  _onFeatureSelected(sel) {
    if (this._draw || this._editing) return
    this._selected = sel
    this._updateEditButton()
  }

  _updateEditButton() {
    const sel = this._selected
    if (this.hasBtnEditTarget) {
      this.btnEditTarget.disabled = !sel
      if (sel) {
        const label = sel.feature.get("numar_cadastral") || `#${sel.feature.get("id")}`
        this.btnEditTarget.title = `Editează ${sel.kind} ${label}`
        this.btnEditTarget.textContent = `✎ Editează ${sel.kind} ${label}`
      } else {
        this.btnEditTarget.title = "Click pe un poligon de pe hartă pentru a-l selecta"
        this.btnEditTarget.textContent = "✎ Editează"
      }
    }
    if (this.hasBtnDeleteTarget) {
      this.btnDeleteTarget.disabled = !sel
      if (sel) {
        const label = sel.feature.get("numar_cadastral") || `#${sel.feature.get("id")}`
        this.btnDeleteTarget.title = `Șterge ${sel.kind} ${label}`
      } else {
        this.btnDeleteTarget.title = "Click pe un poligon de pe hartă pentru a-l selecta"
      }
    }
  }

  async deleteSelected() {
    const sel = this._selected
    if (!sel) {
      this._setStatus("Selectează un poligon pe hartă (click pe el) înainte de Șterge.", "warn")
      return
    }
    const label = sel.feature.get("numar_cadastral") || `#${sel.feature.get("id")}`
    if (!confirm(`Ștergi ${sel.kind} ${label}?\n\nAceastă acțiune e ireversibilă.`)) return

    const url = sel.kind === "cladire"
      ? `/cladiri_cadastrale/${sel.feature.get("id")}`
      : `/parcele_cadastrale/${sel.feature.get("id")}`

    try {
      const res = await fetch(url, {
        method:  "DELETE",
        headers: {
          "X-CSRF-Token": this._csrf(),
          "Accept":       "application/json"
        }
      })
      if (res.ok) {
        this._setStatus(`${sel.kind} ${label} ștearsă.`, "ok")
        // Curăț selecția vizual + state
        this._hartaMap?.clearSelection?.()
        this._selected = null
        this._updateEditButton()
        // Reload layer-ul potrivit
        if (sel.kind === "cladire") this._hartaMap?._loadCladiri()
        else                         this._hartaMap?._loadParcele()
      } else {
        const data = await res.json().catch(() => ({}))
        this._setStatus(`Eroare la ștergere: ${data.error || res.status}`, "warn")
      }
    } catch (e) {
      this._setStatus(`Eroare rețea: ${e.message}`, "warn")
    }
  }

  editSelected() {
    if (!this._selected) {
      this._setStatus("Selectează un poligon pe hartă (click pe el) înainte de Editează.", "warn")
      return
    }
    // Cache local — clearSelection() declanșează event \"feature-deselected\"
    // care, prin listener, setează this._selected = null. Lucrăm pe referință.
    const sel = this._selected
    this.editKindValue = sel.kind
    this.editIdValue   = String(sel.feature.get("id"))
    this._hartaMap?.clearSelection()
    this._enterEditMode(sel.feature, sel.layer)
  }

  // Folosește _verts (deja cleaned de cursor și closing duplicate) ca să
  // randeze cerculețe roșii la fiecare vertex confirmat. Aplicabil atât la
  // edit cât și la digitizare nouă.
  _renderEditVertices() {
    if (!this._editVertexSource) return
    this._editVertexSource.clear()
    this._verts.forEach(v => {
      this._editVertexSource.addFeature(new ol.Feature(new ol.geom.Point([v.x, v.y])))
    })
    // Re-randăm și vecinii editabili (geometriile lor pot fi modificate)
    if (this._editing && this._editFeatureKindMap) {
      this._editFeatureKindMap.forEach((kind, feat) => {
        if (feat === this._editFeature) return
        this._addAllVertexesAsPoints(feat, this._editVertexSource, true)
      })
    }
  }

  _addAllVertexesAsPoints(feat, source, isNeighbor = false) {
    const geom = feat.getGeometry()
    if (!geom) return
    const type = geom.getType()
    let rings = []
    if (type === "Polygon")           rings = geom.getCoordinates()
    else if (type === "MultiPolygon") rings = geom.getCoordinates().flat()
    rings.forEach(ring => {
      const verts = ring.length > 1 ? ring.slice(0, -1) : ring
      verts.forEach(coord => {
        const f = new ol.Feature(new ol.geom.Point(coord))
        if (isNeighbor) f.set("neighborVertex", true)
        source.addFeature(f)
      })
    })
  }

  _renderNeighborVertices(neighbors) {
    if (!this._editVertexSource) return
    neighbors.forEach(feat => {
      this._addAllVertexesAsPoints(feat, this._editVertexSource, true)
      // Track changes la geometria vecinului ca să marcăm ca modified
      const onChange = () => {
        this._modifiedFeatures.add(feat)
        // Re-render cerculețele când se modifică
        this._renderEditVertices()
      }
      const key = feat.getGeometry().on("change", onChange)
      this._editFeatureKindMap.set(feat, this._editFeatureKindMap.get(feat) || "parcela")
      // Stash key for cleanup
      if (!this._neighborChangeKeys) this._neighborChangeKeys = []
      this._neighborChangeKeys.push(key)
    })
  }

  _findEditableNeighbors(feature, distMeters = 1.0) {
    if (!this._hartaMap) return []
    const editGeom = feature.getGeometry()
    const editExt  = editGeom.getExtent()
    const buffered = ol.extent.buffer(editExt, distMeters)
    const out = []
    const sources = [
      [this._hartaMap.parcelLayer.getSource(),  "parcela"],
      [this._hartaMap.cladiriLayer.getSource(), "cladire"]
    ]
    sources.forEach(([src, kind]) => {
      src?.forEachFeatureInExtent(buffered, (f) => {
        if (f === feature) return
        // Doar vecini de același tip cu poligonul editat (parcele cu parcele,
        // clădiri cu clădiri); evităm să tragem clădiri când edităm parcele.
        if (kind !== this.editKindValue) return
        out.push({ feature: f, kind })
      })
    })
    return out
  }

  // ── EDIT MODE: modify geometrie poligon existent ─────────────────────────

  _waitForFeatureAndEdit() {
    // Layer-ul țintă e deja încărcat (parcele/cladiri) sau în curs; așteptăm
    // până feature-ul cu id-ul cerut e în source. Polling la 200ms (max 5s).
    const start = Date.now()
    const poll  = () => {
      const layer = this.editKindValue === "cladire"
        ? this._hartaMap?.cladiriLayer
        : this._hartaMap?.parcelLayer
      if (!layer) {
        if (Date.now() - start < 5000) return setTimeout(poll, 200)
        return
      }
      const feat = layer.getSource().getFeatures().find(f => String(f.get("id")) === String(this.editIdValue))
      if (feat) return this._enterEditMode(feat, layer)
      if (Date.now() - start < 5000) setTimeout(poll, 200)
      else this._setStatus(`Nu am găsit ${this.editKindValue} #${this.editIdValue} pentru editare.`, "warn")
    }
    poll()
  }

  _enterEditMode(feature, sourceLayer) {
    this._editing = true
    this._editFeature = feature
    this._editSourceLayer = sourceLayer
    this._hartaMap?.setDigitizing(true)

    // Forțează închiderea popup-ului de info (în caz că setDigitizing nu a apucat)
    this._hartaMap?._popup?.setPosition(undefined)
    this._hartaMap?.clearSelection?.()

    // Detectează vecinii (parcele/clădiri în limita 1m) și le include în
    // Modify ca să poți edita simultan vertecșii partajati. Topology-aware
    // editing: drag pe un vertex partajat mută în ambele poligoane.
    this._editFeatureKindMap = new Map()
    this._editFeatureKindMap.set(feature, this.editKindValue)
    const neighbors = this._findEditableNeighbors(feature, 1.0)
    neighbors.forEach(n => this._editFeatureKindMap.set(n.feature, n.kind))

    const allEditFeatures = [feature, ...neighbors.map(n => n.feature)]
    const editColl = new ol.Collection(allEditFeatures)
    this._modify = new ol.interaction.Modify({
      features:       editColl,
      pixelTolerance: 12,
      deleteCondition: (evt) => {
        const oe = evt.originalEvent
        return evt.type === "singleclick" && (oe?.shiftKey || oe?.altKey)
      }
    })
    this.map.addInteraction(this._modify)

    // Tracking modificări — set de features modificate (pentru save batch)
    this._modifiedFeatures = new Set([feature])  // primary always considered modified
    this._modify.on("modifyend", (evt) => {
      evt.features.forEach(f => this._modifiedFeatures.add(f))
    })

    // Render cerculețe albastre la fiecare vertex al fiecărui vecin editabil
    // (pe lângă cerculețele roșii ale poligonului primar din _renderEditVertices)
    this._renderNeighborVertices(neighbors.map(n => n.feature))

    // Snap la celelalte features
    this._snapModes = new Set(["endpoint"])
    this._refreshSnap()

    // Extract verts inițial + on change (apelul _renderEditVertices e deja inclus în _extractVerts)
    this._extractVerts(feature.getGeometry())
    this._geomChangeKey = feature.getGeometry().on("change", (e) => {
      this._extractVerts(e.target)
      clearTimeout(this._areaDebounce); clearTimeout(this._topoDebounce)
      this._areaDebounce = setTimeout(() => this._calcArea(), 400)
      this._topoDebounce = setTimeout(() => this._verifyTopology(), 700)
    })

    // Preluăm zoom la feature ca să fie vizibil
    const ext = feature.getGeometry().getExtent()
    this.map.getView().fit(ext, { padding: [60, 60, 60, 60], maxZoom: 19, duration: 250 })

    // Înlocuim butoanele Salvează cu un buton dedicat „Salvează modificări"
    this._injectEditUI()
    this._setStatus(`Editare ${this.editKindValue} #${this.editIdValue} — drag pe vertex pentru a modifica.`, "ok")
    this._calcArea()
    this._verifyTopology()
  }

  _injectEditUI() {
    // Ascund formele de salvare nouă; show un mic header de edit + buton save
    if (this.hasFormParcelaTarget)  this.formParcelaTarget.style.display  = "none"
    if (this.hasFormCladireTarget)  this.formCladireTarget.style.display  = "none"
    const ent = this.element.querySelector(".digi-entity-toggle")
    if (ent) ent.style.display = "none"

    // Inject panou de edit (idempotent)
    if (this.element.querySelector(".digi-edit-panel")) return
    const panel = document.createElement("section")
    panel.className = "digi-section digi-edit-panel"
    panel.innerHTML = `
      <div class="digi-edit-header">Modificare ${this.editKindValue} #${this.editIdValue}</div>
      <ul class="digi-parcela-hint" style="margin:6px 0;padding-left:18px;line-height:1.6">
        <li><b>Drag</b> pe vertex (cerc roșu) → mută vertex</li>
        <li><b>Click pe muchie + drag</b> → adaugă vertex nou</li>
        <li><b>Shift+Click</b> pe vertex → șterge vertex</li>
      </ul>
      <div class="digi-edit-topo-mirror" data-digitizare-target="editTopoMirror"
           style="margin-top:8px;font-size:11px;display:flex;flex-direction:column;gap:3px"></div>
      <button type="button" class="btn btn-primary btn-sm digi-edit-save"
              data-action="click->digitizare#saveEdit"
              style="width:100%;margin-top:8px">💾 Salvează modificări</button>
      <button type="button" class="btn btn-secondary btn-sm"
              style="width:100%;margin-top:6px"
              onclick="window.location.href='/${this.editKindValue === 'cladire' ? 'cladiri_cadastrale' : 'parcele_cadastrale'}/${this.editIdValue}'">
        ✕ Anulează (înapoi la detalii)
      </button>
    `
    // Inserăm panoul la TOP-ul panel-body, ca să fie imediat vizibil sub header
    const body = this.hasPanelBodyTarget ? this.panelBodyTarget : this.element
    const firstSection = body.querySelector(".digi-section")
    if (firstSection) body.insertBefore(panel, firstSection)
    else body.appendChild(panel)
    this._updateSaveAvailability()
  }

  async saveEdit() {
    if (!await this._validateBeforeSave()) return

    // Construim payload pentru save_batch: primary + vecini modificați
    const primary = {
      kind:         this.editKindValue,
      id:           this.editIdValue,
      geom_wkt:     this._buildWktFromGeom(this._editFeature.getGeometry()),
      suprafata_mp: this._areaCalc > 0 ? this._areaCalc.toFixed(4) : null
    }
    const neighbors = []
    if (this._modifiedFeatures && this._editFeatureKindMap) {
      this._modifiedFeatures.forEach(f => {
        if (f === this._editFeature) return
        const kind = this._editFeatureKindMap.get(f)
        if (!kind) return
        neighbors.push({
          kind:     kind,
          id:       String(f.get("id")),
          geom_wkt: this._buildWktFromGeom(f.getGeometry()),
          suprafata_mp: null  // recalcularea suprafeței la vecini se face server-side la save
        })
      })
    }

    this._setStatus(`Salvare: ${1 + neighbors.length} poligon(e)…`)
    try {
      const res = await fetch(this.saveBatchUrlValue, {
        method:  "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this._csrf(),
          "Accept":       "application/json"
        },
        body: JSON.stringify({ primary, neighbors })
      })
      const data = await res.json()
      if (data.ok) {
        window.location.href = data.redirect
      } else {
        this._setStatus("Erori la save: " + (data.errors || []).join(" | "), "warn")
      }
    } catch (e) {
      this._setStatus(`Eroare rețea: ${e.message}`, "warn")
    }
  }

  // Serializează geometry (Polygon sau MultiPolygon) în WKT MULTIPOLYGON
  // direct din coordonatele OL (Stereo 70 nativ).
  _buildWktFromGeom(geom) {
    const type = geom.getType()
    let polygons = []
    if (type === "Polygon")           polygons = [geom.getCoordinates()]
    else if (type === "MultiPolygon") polygons = geom.getCoordinates()
    const polyStrs = polygons.map(rings => {
      const ringStrs = rings.map(ring => {
        // Asigură ring închis
        const closed = ring.length > 0 && (ring[0][0] !== ring[ring.length-1][0] || ring[0][1] !== ring[ring.length-1][1])
          ? [...ring, ring[0]]
          : ring
        return "(" + closed.map(c => `${c[0].toFixed(6)} ${c[1].toFixed(6)}`).join(", ") + ")"
      })
      return "(" + ringStrs.join(", ") + ")"
    })
    return "MULTIPOLYGON(" + polyStrs.join(", ") + ")"
  }

  // În edit mode, suprapunerea se verifică EXCLUDÂND poligonul curent ȘI
  // toți vecinii care au fost modificați în memorie (geometriile lor server
  // sunt încă cele vechi și ar genera fals-pozitive de overlap).
  _verifyTopologyParams() {
    const params = {
      coords:      this._verts.map(v => [v.x, v.y]),
      entity_type: this._editing ? this.editKindValue : this._entityType
    }
    if (this._editing) params.exclude_id = this.editIdValue
    if (this._editing && this._modifiedFeatures) {
      const ids = []
      this._modifiedFeatures.forEach(f => {
        if (f === this._editFeature) return
        ids.push(String(f.get("id")))
      })
      if (ids.length) params.exclude_neighbor_ids = ids
    }
    return params
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  _setStatus(msg, type = "info") {
    this.statusBarTarget.textContent = msg
    this.statusBarTarget.className   = `digi-status digi-status-${type}`
  }

  _csrf() { return document.querySelector('[name="csrf-token"]')?.content ?? "" }
}
