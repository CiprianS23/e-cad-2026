import { Controller } from "@hotwired/stimulus"

const STEREO70 = "+proj=sterea +lat_0=46 +lon_0=25 +k=0.99975 +x_0=500000 +y_0=500000 +ellps=krass +towgs84=33.4,-146.6,-76.3,-0.359,-0.053,0.844,-0.84 +units=m +no_defs"
const FMT = (n) => Number(n).toLocaleString("ro-RO", { minimumFractionDigits: 3, maximumFractionDigits: 3 })
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
    "btnEntityParcela", "btnEntityCladire",
    "panelBody"
  ]

  // ── Lifecycle ────────────────────────────────────────────────────────────

  connect() {
    proj4.defs("EPSG:3844", STEREO70)
    this._verts        = []
    this._drawing      = false
    this._closed       = false
    this._snapPt       = null
    this._refSnap      = []
    this._areaCalc     = 0
    this._areaDebounce = null

    this._layerPoly    = null
    this._layerPreview = null
    this._layerSnap    = null
    this._markerGroup  = null
    this._entityType   = "parcela"
  }

  disconnect() {
    this._detachFromMap()
  }

  // ── Outlet (harta-map) ───────────────────────────────────────────────────

  hartaMapOutletConnected(outlet) {
    this._hartaMap = outlet
    this.map = outlet.map
    this._markerGroup = L.layerGroup().addTo(this.map)

    this._onMouseMoveBound = (e) => this._onMouseMove(e)
    this._onMapClickBound  = (e) => this._onMapClick(e)
    this._onDblClickBound  = (e) => this._onDblClick(e)

    this.map.on("mousemove", this._onMouseMoveBound)
    this.map.on("click",     this._onMapClickBound)
    this.map.on("dblclick",  this._onDblClickBound)
  }

  hartaMapOutletDisconnected() {
    this._detachFromMap()
  }

  _detachFromMap() {
    if (!this.map) return
    this.map.off("mousemove", this._onMouseMoveBound)
    this.map.off("click",     this._onMapClickBound)
    this.map.off("dblclick",  this._onDblClickBound)
    ;["_layerPoly", "_layerPreview", "_layerSnap"].forEach(l => this._removeLayer(l))
    this._markerGroup?.clearLayers()
    if (this._markerGroup) { this.map.removeLayer(this._markerGroup); this._markerGroup = null }
    this.map = null
    this._hartaMap = null
  }

  // ── Public actions ───────────────────────────────────────────────────────

  togglePanel() {
    this.element.classList.toggle("digi-panel--collapsed")
  }

  startDrawing() {
    if (!this.map) return
    this._rebuildRefSnap()
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
    if (this.map) this.map.getContainer().style.cursor = ""
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
    if (this.map) this.map.getContainer().style.cursor = ""
    this.btnStartTarget.classList.remove("btn-active")
    this.btnCloseTarget.disabled = true
    this.btnUndoTarget.disabled  = true
    ;["_layerPoly", "_layerPreview", "_layerSnap"].forEach(l => this._removeLayer(l))
    this._markerGroup?.clearLayers()
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
    const { x, y }  = this._fromLatLng(e.latlng)
    this.cursorXTarget.textContent = FMT(x)
    this.cursorYTarget.textContent = FMT(y)

    if (!this._drawing) return

    const snap = this._findSnap(e.latlng)
    this._snapPt = snap
    this._updateSnapIndicator(snap, e.latlng)

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
    if (e.originalEvent._digitizareDblClick) return

    const latlng = this._snapPt || e.latlng
    const { x, y } = this._fromLatLng(latlng)
    this._addVertex(x, y)
  }

  _onDblClick(e) {
    if (!this._drawing || this._verts.length < 3) return
    e.originalEvent._digitizareDblClick = true
    this.closePolygon()
  }

  // ── Locate UAT (autofill județ/localitate) ───────────────────────────────

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

  // ── Snap ─────────────────────────────────────────────────────────────────

  _findSnap(latlng) {
    if (!this.map) return null
    const px  = this.map.latLngToLayerPoint(latlng)
    let best  = null
    let bestD = this.snapToleranceValue

    const check = (ll) => {
      const d = px.distanceTo(this.map.latLngToLayerPoint(ll))
      if (d < bestD) { bestD = d; best = ll }
    }

    this._verts.forEach(v => check(this._toLatLng(v.x, v.y)))
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
    if (!this._hartaMap) return
    const addCoords = (layer) => {
      const geom = layer.feature?.geometry
      if (!geom) return
      const rings = geom.type === "Polygon"      ? geom.coordinates :
                    geom.type === "MultiPolygon"  ? geom.coordinates.flat() : []
      rings.forEach(ring => ring.forEach(([lng, lat]) => this._refSnap.push(L.latLng(lat, lng))))
    }
    this._hartaMap.cgxmlLayer?.eachLayer(addCoords)
    this._hartaMap.parcelLayer?.eachLayer(addCoords)
    this._hartaMap.cladiriLayer?.eachLayer(addCoords)
  }

  // ── Vertex management ────────────────────────────────────────────────────

  _addVertex(x, y) {
    this._verts.push({ x, y })
    const marker = L.circleMarker(this._toLatLng(x, y), {
      radius: 4, color: "#1d4ed8", fillColor: "#fff", fillOpacity: 1, weight: 2, interactive: false
    })
    marker.bindTooltip(`<b>#${this._verts.length}</b><br>X: ${FMT(x)}<br>Y: ${FMT(y)}`,
      { permanent: false, direction: "top", className: "digi-vertex-tooltip" })
    this._markerGroup.addLayer(marker)

    this._updatePolyPreview()
    this._updateVertexList()

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
    if (this[name] && this.map) { this.map.removeLayer(this[name]); this[name] = null }
  }

  _setStatus(msg, type = "info") {
    this.statusBarTarget.textContent  = msg
    this.statusBarTarget.className    = `digi-status digi-status-${type}`
  }

  _csrf() {
    return document.querySelector('[name="csrf-token"]')?.content ?? ""
  }
}
