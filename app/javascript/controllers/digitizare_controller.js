import { Controller } from "@hotwired/stimulus"

const STEREO70 = "+proj=sterea +lat_0=46 +lon_0=25 +k=0.99975 +x_0=500000 +y_0=500000 +ellps=krass +towgs84=33.4,-146.6,-76.3,-0.359,-0.053,0.844,-0.84 +units=m +no_defs"
const FMT = (n) => Number(n).toLocaleString("ro-RO", { minimumFractionDigits: 3, maximumFractionDigits: 3 })
const FMT2 = (n) => Number(n).toLocaleString("ro-RO", { minimumFractionDigits: 2, maximumFractionDigits: 2 })

export default class extends Controller {
  static values = {
    calcUrl:       String,
    exportDxfUrl:  String,
    cgxmlUrl:      String,
    parcelUrl:     String,
    cladireUrl:    String,
    mapproxyUrl:   String,
    uatUrl:             String,
    locateUatUrl:  String,
    snapTolerance: { type: Number, default: 15 }
  }

  static targets = [
    "mapEl",
    "cursorX", "cursorY",
    "snapDot", "snapLabel", "snapSlider", "snapToleranceVal",
    "btnStart", "btnClose", "btnUndo",
    "statusBar",
    "vertexTbody", "vertexCount",
    "inputX", "inputY",
    "areaCalc", "areaAct", "areaDiff",
    "topologyMsg",
    "wktField", "saveForm", "saveAreaField",
    "wktFieldCladire", "saveFormCladire", "saveAreaFieldCladire",
    "formParcela", "formCladire",
    "btnEntityParcela", "btnEntityCladire"
  ]

  // ── Lifecycle ────────────────────────────────────────────────────────────

  connect() {
    proj4.defs("EPSG:3844", STEREO70)
    this._verts       = []        // [{x, y}] Stereo70
    this._drawing     = false
    this._closed      = false
    this._snapPt      = null      // L.LatLng | null
    this._refSnap     = []        // L.LatLng[] from CGXML layer
    this._areaCalc    = 0
    this._areaDebounce = null

    this._layerPoly    = null     // L.Polygon preview
    this._layerPreview = null     // L.Polyline cursor→last vertex
    this._layerSnap    = null     // L.CircleMarker snap indicator
    this._markerGroup  = null     // L.LayerGroup vertex markers
    this._uatLayer     = null     // L.GeoJSON UAT boundaries
    this._cladireLayer = null     // L.GeoJSON cladiri cadastrale
    this._entityType = "parcela"

    this._initMap()
    this._loadParcelLayer()
    this._loadCladireLayer()
    this._loadCgxmlLayer()
  }

  disconnect() {
    this.map?.remove()
  }

  // ── Map init ─────────────────────────────────────────────────────────────

  _initMap() {
    this.map = L.map(this.mapElTarget, { center: [45.75, 24.9], zoom: 7, zoomControl: true })

    const osm = L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png",
      { attribution: "© OpenStreetMap contributors", maxZoom: 19 })

    const baseLayers = { "OpenStreetMap": osm }
    if (this.mapproxyUrlValue) {
      const orto = L.tileLayer(
        `${this.mapproxyUrlValue}/tms/1.0.0/ortoplan/webmercator/{z}/{x}/{y}.jpeg`,
        { attribution: "© ANCPI – Ortofotoplan", maxZoom: 20, tms: true }
      )
      baseLayers["Ortofotoplan"] = orto
      orto.addTo(this.map)
    } else {
      osm.addTo(this.map)
    }

    this._uatLayer = L.geoJSON(null, {
      style: () => ({
        color:       "#6b21a8",
        weight:      1.2,
        fillColor:   "#a855f7",
        fillOpacity: 0.06,
        dashArray:   "4 3"
      }),
      onEachFeature: (f, l) => {
        const p = f.properties || {}
        l.bindTooltip(p.name || p.nat_code || "UAT", { sticky: true, className: "uat-tooltip" })
        l.on("mouseover", () => l.setStyle({ weight: 2, fillOpacity: 0.18 }))
        l.on("mouseout",  () => this._uatLayer.resetStyle(l))
      }
    })

    this._parcelLayer = L.geoJSON(null, {
      style:         () => ({ color: "#1d4ed8", weight: 1.5, fillOpacity: 0.15, fillColor: "#3b82f6" }),
      onEachFeature: (f, l) => {
        const p = f.properties || {}
        l.bindPopup(`<b>${p.numar_cadastral || "—"}</b><br>${p.localitate || ""} ${p.judet || ""}`.trim())
      }
    })

    this._cladireLayer = L.geoJSON(null, {
      style:         () => ({ color: "#b45309", weight: 1.5, fillOpacity: 0.2, fillColor: "#fbbf24" }),
      onEachFeature: (f, l) => {
        const p = f.properties || {}
        l.bindPopup(
          `<b>${p.numar_cadastral || "—"}</b> · Clădire<br>` +
          `${[p.destinatie, p.regim_inaltime].filter(Boolean).join(", ") || "—"}<br>` +
          `${p.localitate || ""} ${p.judet || ""}`.trim()
        )
      }
    })

    this._cgxmlLayer = L.geoJSON(null, {
      style:          (f) => this._cgxmlStyle(f),
      onEachFeature:  (f, l) => this._cgxmlPopup(f, l)
    })
    this._markerGroup = L.layerGroup().addTo(this.map)

    L.control.layers(baseLayers, {
      "Limite UAT":         this._uatLayer,
      "Parcele cadastrale": this._parcelLayer,
      "Clădiri cadastrale": this._cladireLayer,
      "Imobile CGXML":      this._cgxmlLayer
    }, { collapsed: false }).addTo(this.map)
    this._uatLayer.addTo(this.map)
    this._parcelLayer.addTo(this.map)
    this._cladireLayer.addTo(this.map)
    this._cgxmlLayer.addTo(this.map)

    this.map.on("mousemove",  (e) => this._onMouseMove(e))
    this.map.on("click",      (e) => this._onMapClick(e))
    this.map.on("dblclick",   (e) => this._onDblClick(e))
  }

  async _loadParcelLayer() {
    if (!this.parcelUrlValue) return
    try {
      const res  = await fetch(this.parcelUrlValue)
      const data = await res.json()
      this._parcelLayer.addData(data)
      if (this._parcelLayer.getLayers().length > 0) {
        this.map.fitBounds(this._parcelLayer.getBounds(), { padding: [40, 40] })
        this._loadUatLayer(this._parcelLayer.getBounds().getCenter())
      }
      this._rebuildRefSnap()
    } catch (e) {
      console.warn("Parcel layer error:", e)
    }
  }

  async _loadCgxmlLayer() {
    if (!this.cgxmlUrlValue) return
    try {
      const res  = await fetch(this.cgxmlUrlValue)
      const data = await res.json()
      this._cgxmlLayer.addData(data)
      if (this._cgxmlLayer.getLayers().length > 0 && this._parcelLayer.getLayers().length === 0) {
        this.map.fitBounds(this._cgxmlLayer.getBounds(), { padding: [40, 40] })
        this._loadUatLayer(this._cgxmlLayer.getBounds().getCenter())
      }
      this._rebuildRefSnap()
    } catch (e) {
      console.warn("CGXML layer error:", e)
    }
  }

  async _loadCladireLayer() {
    if (!this.cladireUrlValue) return
    try {
      const res  = await fetch(this.cladireUrlValue)
      const data = await res.json()
      this._cladireLayer.addData(data)
    } catch (e) {
      console.warn("Cladire layer error:", e)
    }
  }

  async _loadUatLayer(center) {
    if (!this.uatUrlValue || !center) return
    try {
      const url  = `${this.uatUrlValue}?lat=${center.lat}&lng=${center.lng}`
      const res  = await fetch(url)
      const data = await res.json()
      this._uatLayer.clearLayers()
      this._uatLayer.addData(data)
    } catch (e) {
      console.warn("UAT layer error:", e)
    }
  }

  async _locateUat() {
    if (!this.locateUatUrlValue || this._verts.length < 3) return
    try {
      const res  = await fetch(this.locateUatUrlValue, {
        method:  "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf() },
        body:    JSON.stringify({ coords: this._verts.map(v => [v.x, v.y]) })
      })
      const data = await res.json()
      if (!data.judet) return

      this.element.querySelectorAll('[data-siruta-target="judetInput"]').forEach(el => this._flashFill(el, data.judet))
      this.element.querySelectorAll('[data-siruta-target="localitateInput"]').forEach(el => this._flashFill(el, data.localitate))
    } catch (e) {
      console.warn("Locate UAT error:", e)
    }
  }

  _flashFill(input, value) {
    input.value = value
    input.classList.add("digi-autofill")
    setTimeout(() => input.classList.remove("digi-autofill"), 1800)
  }

  // ── Public actions ───────────────────────────────────────────────────────

  startDrawing() {
    this._drawing = true
    this._closed  = false
    this.map.getContainer().style.cursor = "crosshair"
    this.btnStartTarget.classList.add("btn-active")
    this.btnCloseTarget.disabled = false
    this.btnUndoTarget.disabled  = false
    this._setStatus("Clic pe hartă pentru primul vertex.")
  }

  closePolygon() {
    if (this._verts.length < 3) {
      this._setStatus("Sunt necesare cel puțin 3 puncte.", "warn")
      return
    }
    this._drawing = false
    this._closed  = true
    this.map.getContainer().style.cursor = ""
    this.btnStartTarget.classList.remove("btn-active")
    this.btnCloseTarget.disabled = true
    this._removeLayer("_layerPreview")
    this._removeLayer("_layerSnap")
    this._updatePolyPreview()
    this._calcArea()
    this._locateUat()
    this._setStatus(`Poligon închis — ${this._verts.length} vertecși.`, "ok")
  }

  undoVertex() {
    if (!this._verts.length) return
    this._verts.pop()
    this._rebuildMarkers()
    this._updatePolyPreview()
    this._updateVertexList()
    if (this._verts.length >= 3) this._calcArea()
    else { this.areaCalcTarget.textContent = "—"; this.areaDiffTarget.textContent = "—" }
    this._setStatus(`Vertex eliminat. Rămân ${this._verts.length}.`)
  }

  clearAll() {
    this._verts   = []
    this._drawing = false
    this._closed  = false
    this.map.getContainer().style.cursor = ""
    this.btnStartTarget.classList.remove("btn-active")
    this.btnCloseTarget.disabled = true
    this.btnUndoTarget.disabled  = true
    ;["_layerPoly", "_layerPreview", "_layerSnap"].forEach(l => this._removeLayer(l))
    this._markerGroup.clearLayers()
    this._updateVertexList()
    this.areaCalcTarget.textContent  = "—"
    this.areaDiffTarget.textContent  = "—"
    this.topologyMsgTarget.textContent = ""
    this._setStatus("Toți vertecșii au fost șterși.")
  }

  addManualPoint() {
    const x = parseFloat(this.inputXTarget.value)
    const y = parseFloat(this.inputYTarget.value)
    if (isNaN(x) || isNaN(y)) { this._setStatus("Coordonate invalide.", "warn"); return }
    this._addVertex(x, y)
    this.inputXTarget.value = ""
    this.inputYTarget.value = ""
    this.inputXTarget.focus()
  }

  importTxt(event) {
    const file = event.target.files[0]
    if (!file) return
    const reader = new FileReader()
    reader.onload = (e) => {
      const pts = this._parseTxt(e.target.result)
      if (!pts.length) { this._setStatus("Fișier TXT fără date valide.", "warn"); return }
      pts.forEach(({ x, y }) => this._addVertex(x, y))
      this._setStatus(`${pts.length} puncte importate din ${file.name}.`, "ok")
      if (this._verts.length >= 3) this._calcArea()
      event.target.value = ""
    }
    reader.readAsText(file)
  }

  toleranceChanged() {
    this.snapToleranceValue = parseInt(this.snapSliderTarget.value)
    this.snapToleranceValTarget.textContent = this.snapToleranceValue
  }

  updateDiff() {
    this._updateDiffDisplay()
  }

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
      const a    = Object.assign(document.createElement("a"), { href: url, download: "parcela.dxf" })
      a.click()
      URL.revokeObjectURL(url)
    } catch (e) {
      this._setStatus("Eroare export DXF: " + e.message, "warn")
    }
  }

  showRaport() {
    if (this._verts.length < 3) { this._setStatus("Niciun poligon de raportat.", "warn"); return }
    const html = this._buildRaportHtml()
    const win  = window.open("", "_blank")
    win.document.write(html)
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

  // ── Map event handlers ───────────────────────────────────────────────────

  _onMouseMove(e) {
    // Coordonate Stereo70 la cursor
    const { x, y }  = this._fromLatLng(e.latlng)
    this.cursorXTarget.textContent = FMT(x)
    this.cursorYTarget.textContent = FMT(y)

    if (!this._drawing) return

    // Snap
    const snap = this._findSnap(e.latlng)
    this._snapPt = snap
    this._updateSnapIndicator(snap, e.latlng)

    // Linie preview de la ultimul vertex la cursor
    if (this._verts.length > 0) {
      const target = snap || e.latlng
      const last   = this._toLatLng(this._verts[this._verts.length - 1].x, this._verts[this._verts.length - 1].y)
      this._removeLayer("_layerPreview")
      this._layerPreview = L.polyline([last, target], {
        color: "#64748b", weight: 1.5, dashArray: "6 3", interactive: false
      }).addTo(this.map)
    }
  }

  _onMapClick(e) {
    if (!this._drawing) return
    // Ignorăm al doilea clic din dblclick
    if (e.originalEvent._digitizareDblClick) return

    const latlng = this._snapPt || e.latlng
    const { x, y } = this._fromLatLng(latlng)
    this._addVertex(x, y)
  }

  _onDblClick(e) {
    if (!this._drawing || this._verts.length < 3) return
    // Marcăm evenimentul ca dublu-clic ca să nu se adauge un vertex extra
    e.originalEvent._digitizareDblClick = true
    this.closePolygon()
  }

  // ── Snap ─────────────────────────────────────────────────────────────────

  _findSnap(latlng) {
    const px  = this.map.latLngToLayerPoint(latlng)
    let best  = null
    let bestD = this.snapToleranceValue

    const check = (ll) => {
      const d = px.distanceTo(this.map.latLngToLayerPoint(ll))
      if (d < bestD) { bestD = d; best = ll }
    }

    // Snap la propriii vertecși
    this._verts.forEach(v => check(this._toLatLng(v.x, v.y)))
    // Snap la stratul de referință CGXML
    this._refSnap.forEach(ll => check(ll))

    return best
  }

  _updateSnapIndicator(snapLatlng, cursorLatlng) {
    this._removeLayer("_layerSnap")
    const pos     = snapLatlng || cursorLatlng
    const snapped = !!snapLatlng

    this._layerSnap = L.circleMarker(pos, {
      radius:      snapped ? 7 : 4,
      color:       snapped ? "#22c55e" : "#ef4444",
      fillColor:   snapped ? "#22c55e" : "transparent",
      fillOpacity: snapped ? 0.3 : 0,
      weight:      2,
      interactive: false
    }).addTo(this.map)

    this.snapDotTarget.style.background = snapped ? "#22c55e" : "#ef4444"
    this.snapLabelTarget.textContent    = snapped ? "Snap: ACTIV" : "Snap: liber"
  }

  _rebuildRefSnap() {
    this._refSnap = []
    const addCoords = (layer) => {
      const geom = layer.feature?.geometry
      if (!geom) return
      const rings = geom.type === "Polygon"      ? geom.coordinates :
                    geom.type === "MultiPolygon"  ? geom.coordinates.flat() : []
      rings.forEach(ring => ring.forEach(([lng, lat]) => this._refSnap.push(L.latLng(lat, lng))))
    }
    this._cgxmlLayer.eachLayer(addCoords)
    this._parcelLayer.eachLayer(addCoords)
  }

  // ── Vertex management ────────────────────────────────────────────────────

  _addVertex(x, y) {
    this._verts.push({ x, y })
    // Marker pe hartă
    const marker = L.circleMarker(this._toLatLng(x, y), {
      radius: 4, color: "#1d4ed8", fillColor: "#fff", fillOpacity: 1, weight: 2, interactive: false
    })
    // Tooltip cu coordonate
    marker.bindTooltip(`<b>#${this._verts.length}</b><br>X: ${FMT(x)}<br>Y: ${FMT(y)}`,
      { permanent: false, direction: "top", className: "digi-vertex-tooltip" })
    this._markerGroup.addLayer(marker)

    this._updatePolyPreview()
    this._updateVertexList()

    // Dacă avem ≥3 vertecși, calculăm suprafața cu debounce
    if (this._verts.length >= 3) {
      clearTimeout(this._areaDebounce)
      this._areaDebounce = setTimeout(() => this._calcArea(), 400)
    }
    this._setStatus(`Vertex #${this._verts.length}: X=${FMT(x)}, Y=${FMT(y)}`)
  }

  _rebuildMarkers() {
    this._markerGroup.clearLayers()
    this._verts.forEach((v, i) => {
      const marker = L.circleMarker(this._toLatLng(v.x, v.y), {
        radius: 4, color: "#1d4ed8", fillColor: "#fff", fillOpacity: 1, weight: 2, interactive: false
      })
      marker.bindTooltip(`<b>#${i + 1}</b><br>X: ${FMT(v.x)}<br>Y: ${FMT(v.y)}`,
        { permanent: false, direction: "top", className: "digi-vertex-tooltip" })
      this._markerGroup.addLayer(marker)
    })
  }

  _updatePolyPreview() {
    this._removeLayer("_layerPoly")
    if (this._verts.length < 2) return
    const lls = this._verts.map(v => this._toLatLng(v.x, v.y))
    const opts = { color: "#1d4ed8", weight: 2, fillColor: "#93c5fd", fillOpacity: 0.25, interactive: false }
    this._layerPoly = (this._closed && this._verts.length >= 3)
      ? L.polygon(lls, opts).addTo(this.map)
      : L.polyline(lls, { color: "#1d4ed8", weight: 2, interactive: false }).addTo(this.map)
  }

  // ── Vertex list UI ───────────────────────────────────────────────────────

  _updateVertexList() {
    const tbody = this.vertexTbodyTarget
    tbody.innerHTML = ""
    this._verts.forEach((v, i) => {
      const tr = document.createElement("tr")
      tr.innerHTML = `
        <td class="vt-no">${i + 1}</td>
        <td class="vt-coord">${FMT(v.x)}</td>
        <td class="vt-coord">${FMT(v.y)}</td>
        <td><button class="digi-del-btn" data-idx="${i}" title="Șterge">✕</button></td>
      `
      tr.querySelector(".digi-del-btn").addEventListener("click", () => {
        this._verts.splice(i, 1)
        this._rebuildMarkers()
        this._updatePolyPreview()
        this._updateVertexList()
        if (this._verts.length >= 3) this._calcArea()
        else this.areaCalcTarget.textContent = "—"
      })
      tbody.appendChild(tr)
    })
    this.vertexCountTarget.textContent = this._verts.length
  }

  // ── Area calculation ─────────────────────────────────────────────────────

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
      this.areaCalcTarget.textContent = this._areaCalc > 0
        ? `${FMT2(this._areaCalc)} mp`
        : "—"

      // Topologie
      const msgs = []
      if (data.is_valid  === false) msgs.push("⚠ Poligon invalid (auto-intersecție)")
      if (data.is_simple === false) msgs.push("⚠ Poligon non-simplu")
      this.topologyMsgTarget.innerHTML = msgs.map(m => `<span class="topo-warn">${m}</span>`).join("")

      this._updateDiffDisplay()
    } catch (e) {
      console.warn("Eroare calcul suprafață:", e)
    }
  }

  _updateDiffDisplay() {
    const act  = parseFloat(this.areaActTarget.value)
    const calc = this._areaCalc
    if (!act || !calc) { this.areaDiffTarget.textContent = "—"; this.areaDiffTarget.className = "digi-area-diff"; return }
    const pct  = ((calc - act) / act) * 100
    const sign = pct >= 0 ? "▲ +" : "▼ "
    this.areaDiffTarget.textContent  = `${sign}${Math.abs(pct).toFixed(2)}%`
    this.areaDiffTarget.className    = `digi-area-diff ${Math.abs(pct) <= 3 ? "diff-ok" : Math.abs(pct) <= 10 ? "diff-warn" : "diff-bad"}`
  }

  // ── TXT import ───────────────────────────────────────────────────────────

  _parseTxt(content) {
    const results = []
    content.trim().split(/\r?\n/).forEach(line => {
      const raw = line.trim()
      if (!raw || raw.startsWith("#") || raw.startsWith("//")) return
      // Separator: virgulă, punct și virgulă, tab, spații
      const parts = raw.replace(/,/g, ".").split(/[\s;]+/).filter(Boolean)
      let x, y
      if (parts.length >= 3) { x = parseFloat(parts[1]); y = parseFloat(parts[2]) }
      else if (parts.length === 2) { x = parseFloat(parts[0]); y = parseFloat(parts[1]) }
      if (!isNaN(x) && !isNaN(y)) results.push({ x, y })
    })
    return results
  }

  // ── WKT / DXF / Raport ───────────────────────────────────────────────────

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
        .summary{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-top:8px}
        .sum-box{border:1px solid #e5e7eb;border-radius:6px;padding:10px}
        .sum-val{font-size:20px;font-weight:700;color:#1d4ed8}
        .diff-ok{color:#16a34a} .diff-warn{color:#d97706} .diff-bad{color:#dc2626}
        @media print{button{display:none}}
      </style>
    </head><body>
      <h1>Raport Digitizare Parcelă Cadastrală</h1>
      <p>Generat: ${new Date().toLocaleString("ro-RO")} | Proiecție: Stereo 70 (EPSG:3844)</p>
      <h2>Coordonate vertecși</h2>
      <table>
        <thead><tr><th>#</th><th>X — Est (m)</th><th>Y — Nord (m)</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
      <h2>Suprafețe</h2>
      <div class="summary">
        <div class="sum-box">
          <div style="color:#6b7280;font-size:11px">CALCULATĂ (PostGIS)</div>
          <div class="sum-val">${FMT2(calc)} mp</div>
        </div>
        <div class="sum-box">
          <div style="color:#6b7280;font-size:11px">DIN ACT</div>
          <div class="sum-val">${act ? FMT2(act) + " mp" : "—"}</div>
        </div>
        <div class="sum-box">
          <div style="color:#6b7280;font-size:11px">DIFERENȚĂ</div>
          <div class="sum-val ${Math.abs(parseFloat(pct)) <= 3 ? 'diff-ok' : Math.abs(parseFloat(pct)) <= 10 ? 'diff-warn' : 'diff-bad'}">
            ${pct !== "—" ? (parseFloat(pct) >= 0 ? "+" : "") + pct + "%" : "—"}
          </div>
        </div>
        <div class="sum-box">
          <div style="color:#6b7280;font-size:11px">NR. VERTECȘI</div>
          <div class="sum-val">${this._verts.length}</div>
        </div>
      </div>
      <h2>WKT (Stereo 70)</h2>
      <pre style="font-size:10px;background:#f8fafc;padding:10px;overflow:auto;word-break:break-all">${this._buildWkt()}</pre>
      <p style="margin-top:20px"><button onclick="window.print()" style="padding:8px 20px;background:#1d4ed8;color:#fff;border:none;border-radius:4px;cursor:pointer">Printează raportul</button></p>
    </body></html>`
  }

  // ── CGXML layer style & popup ────────────────────────────────────────────

  _cgxmlStyle(feature) {
    const isBuilding = feature.properties?.entity_type === "building"
    return {
      color:       isBuilding ? "#b91c1c" : "#92400e",
      weight:      isBuilding ? 1.5 : 2,
      fillColor:   isBuilding ? "#fca5a5" : "#fcd34d",
      fillOpacity: 0.4
    }
  }

  _cgxmlPopup(feature, layer) {
    const p  = feature.properties ?? {}
    const lb = p.entity_type === "building" ? "Construcție" : "Imobil"
    const mp = (v) => v != null ? `${Number(v).toLocaleString("ro-RO", { maximumFractionDigits: 2 })} mp` : "—"

    layer.bindPopup(`
      <div style="font-size:12px;min-width:180px">
        <b>${lb} #${p.id ?? "?"}</b>
        <table style="width:100%;margin-top:6px;border-collapse:collapse">
          <tr><td style="color:#9ca3af;padding:2px 6px 2px 0">Fișier</td>
              <td style="font-family:monospace;font-size:11px">${p.filename ?? "—"}</td></tr>
          <tr><td style="color:#9ca3af;padding:2px 6px 2px 0">Suprafață</td>
              <td>${mp(p.measuredarea)}</td></tr>
          ${p.cadgenno ? `<tr><td style="color:#9ca3af;padding:2px 6px 2px 0">Nr. cad.</td>
              <td style="font-family:monospace">${p.cadgenno}</td></tr>` : ""}
          ${p.e2identifier ? `<tr><td style="color:#9ca3af;padding:2px 6px 2px 0">E2 ID</td>
              <td style="font-family:monospace">${p.e2identifier}</td></tr>` : ""}
        </table>
      </div>
    `, { maxWidth: 220 })

    layer.on("mouseover", () => layer.setStyle({ weight: 3, fillOpacity: 0.65 }))
    layer.on("mouseout",  () => this._cgxmlLayer.resetStyle(layer))
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  _toLatLng(x, y) {
    const [lng, lat] = proj4("EPSG:3844", "EPSG:4326", [x, y])
    return L.latLng(lat, lng)
  }

  _fromLatLng(latlng) {
    const [x, y] = proj4("EPSG:4326", "EPSG:3844", [latlng.lng, latlng.lat])
    return { x, y }
  }

  _removeLayer(name) {
    if (this[name]) { this.map.removeLayer(this[name]); this[name] = null }
  }

  _setStatus(msg, type = "info") {
    this.statusBarTarget.textContent  = msg
    this.statusBarTarget.className    = `digi-status digi-status-${type}`
  }

  _csrf() {
    return document.querySelector('[name="csrf-token"]')?.content ?? ""
  }
}
