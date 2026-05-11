import { Controller } from "@hotwired/stimulus"

// Georef Editor — ecran dual-viewport pentru plasare GCP.
// Pane STÂNGA: imaginea sursă (PNG preview generat la upload).
// Pane DREAPTA: harta de referință în Stereo70 cu OSM/Ortofoto + parcele/
//   clădiri/CGXML/UAT existente; click pe orice geometrie → folosește
//   centroidul ei ca țintă. Alternativ: input manual X, Y în Stereo70.
//
// Workflow GCP:
//   1. Click stânga (sursă) → marker pending pe imagine, prompt pentru țintă
//   2. Click pe harta dreaptă SAU input manual SAU click pe geometrie → POST
//   3. Repetă pentru ≥3 GCP-uri; "Recalculează" rulează afină preview;
//      "Finalize" rulează gdalwarp.
export default class extends Controller {
  static targets = [
    "srcMap", "refMap", "gcpList", "gcpCount", "rms",
    "leftMode", "rightMode", "srcCoord", "refCoord", "srcDims",
    "status", "computeBtn", "finalizeBtn", "warpMethod", "gcpHint",
    "manualX", "manualY", "manualApply", "diag"
  ]
  static values = {
    planId:              Number,
    rasterUrl:           String,
    originalWidth:       Number,
    originalHeight:      Number,
    cpsUrl:              String,
    georefUrl:           String,
    finalizeUrl:         String,
    planUrl:             String,
    cgxmlGeojsonUrl:     String,
    parceleGeojsonUrl:   String,
    cladiriGeojsonUrl:   String,
    uatGeojsonUrl:       String,
    mapproxyUrl:         String
  }

  connect() {
    this._csrf       = document.querySelector('meta[name="csrf-token"]')?.content
    this._pendingPx  = null
    this._gcps       = []
    this._diag       = []
    try {
      this._registerProjection()
      // Reference map: independent de imaginea sursă, build IMEDIAT.
      this._buildReferenceMap()
      this._loadGcps()
      this._appendDiag("Reference map: build OK")
    } catch (e) {
      this._appendDiag(`Eroare reference map: ${e.message}`)
      console.error(e)
    }
    // Source map: poate eșua dacă dimensiunile lipsesc sau imaginea nu se
    // încarcă în browser (TIFF/PDF). Pipeline separat cu fallback timeout.
    if (this.originalWidthValue > 0 && this.originalHeightValue > 0) {
      this._safeBuildSource()
    } else {
      this._ensureDimensions().finally(() => this._safeBuildSource())
    }
  }

  _safeBuildSource() {
    try {
      this._buildSourceMap()
      this._appendDiag("Source map: build OK")
    } catch (e) {
      this._appendDiag(`Eroare source map: ${e.message}`)
      console.error(e)
    }
  }

  _appendDiag(msg) {
    this._diag.push(msg)
    if (this.hasDiagTarget) {
      this.diagTarget.textContent = this._diag.join(" · ")
    }
  }

  // ── Proiecții ────────────────────────────────────────────────────────────

  _registerProjection() {
    if (!proj4.defs("EPSG:3844")) {
      proj4.defs("EPSG:3844",
        "+proj=sterea +lat_0=46 +lon_0=25 +k=0.99975 +x_0=500000 +y_0=500000 " +
        "+ellps=krass +towgs84=33.4,-146.6,-76.3,-0.359,-0.053,0.844,-0.84 +units=m +no_defs")
    }
    if (ol.proj?.proj4) ol.proj.proj4.register(proj4)
    const proj = ol.proj.get("EPSG:3844")
    if (proj && !proj.getExtent()) proj.setExtent([120000, 250000, 900000, 800000])

    if (!ol.proj.get("PLAN-PIXEL")) {
      const W = this.originalWidthValue || 10000
      const H = this.originalHeightValue || 10000
      const pixelProj = new ol.proj.Projection({
        code:   "PLAN-PIXEL",
        units:  "pixels",
        extent: [0, -H, W, 0]
      })
      ol.proj.addProjection(pixelProj)
    }
  }

  async _ensureDimensions() {
    if (this.originalWidthValue > 0 && this.originalHeightValue > 0) return
    if (!this.rasterUrlValue) return
    return new Promise((resolve) => {
      let done = false
      const finish = () => { if (!done) { done = true; resolve() } }
      const safety = setTimeout(() => { this._appendDiag("Timeout încărcare imagine"); finish() }, 5000)
      const img = new Image()
      img.onload = async () => {
        clearTimeout(safety)
        this.originalWidthValue  = img.naturalWidth
        this.originalHeightValue = img.naturalHeight
        if (this.hasSrcDimsTarget) {
          this.srcDimsTarget.textContent = `${img.naturalWidth} × ${img.naturalHeight} px`
        }
        await fetch(this.planUrlValue, {
          method: "PATCH",
          credentials: "same-origin",
          headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf, Accept: "application/json" },
          body: JSON.stringify({ gis_georef_plan: {
            original_width: img.naturalWidth, original_height: img.naturalHeight
          }})
        }).catch(() => {})
        finish()
      }
      img.onerror = () => {
        clearTimeout(safety)
        this._appendDiag("Browser nu poate încărca imaginea sursă (format nesuportat?)")
        finish()
      }
      img.src = this.rasterUrlValue
    })
  }

  // ── Source pane (imaginea sursă) ─────────────────────────────────────────

  _buildSourceMap() {
    if (!this.hasSrcMapTarget) return
    const W = this.originalWidthValue
    const H = this.originalHeightValue
    if (!W || !H) {
      this.srcMapTarget.innerHTML = "<p class='georef-empty'>Imaginea nu se poate afișa.<br>Dimensiunile nu au fost detectate.</p>"
      return
    }
    // Re-creează proiecția PLAN-PIXEL cu dim corecte (dacă a fost creată cu fallback)
    const existing = ol.proj.get("PLAN-PIXEL")
    if (existing) existing.setExtent([0, -H, W, 0])

    const extent = [0, -H, W, 0]

    this._srcImageLayer = new ol.layer.Image({
      source: new ol.source.ImageStatic({
        url:           this.rasterUrlValue,
        imageExtent:   extent,
        projection:    "PLAN-PIXEL"
      })
    })

    this._srcGcpSource = new ol.source.Vector()
    this._srcGcpLayer  = new ol.layer.Vector({
      source: this._srcGcpSource,
      style:  this._gcpStyle.bind(this),
      zIndex: 500
    })

    this._srcMap = new ol.Map({
      target:   this.srcMapTarget,
      controls: ol.control.defaults.defaults({ attribution: false, zoom: true }),
      view:     new ol.View({
        projection: "PLAN-PIXEL",
        center:     [W / 2, -H / 2],
        zoom:       1,
        minZoom:    -3,
        maxZoom:    8,
        extent:     extent
      }),
      layers: [this._srcImageLayer, this._srcGcpLayer]
    })

    this._srcMap.getView().fit(extent, { padding: [20, 20, 20, 20] })

    this._srcMap.on("singleclick", (evt) => this._onSourceClick(evt))
    this._srcMap.on("pointermove", (evt) => {
      const [x, y] = evt.coordinate
      if (this.hasSrcCoordTarget) {
        this.srcCoordTarget.textContent = `Pixel: ${Math.round(x)}, ${Math.round(-y)}`
      }
    })

    // În unele cazuri OL nu detectează corect size-ul la mount; forțăm refresh.
    setTimeout(() => this._srcMap.updateSize(), 50)
    setTimeout(() => this._srcMap.updateSize(), 500)

    this._loadSourceMarkers()
  }

  // ── Reference pane (harta cu OSM + ortofoto + geometriile existente) ─────

  _buildReferenceMap() {
    if (!this.hasRefMapTarget) return

    // Sursa OSM via MapProxy (când e online) cu fallback direct la OSM.
    const osmFallback = () => new ol.source.OSM()
    let osmSource
    if (this.mapproxyUrlValue) {
      osmSource = new ol.source.XYZ({
        url: `${this.mapproxyUrlValue}/tms/1.0.0/osm_3857/webmercator/{z}/{x}/{-y}.png`,
        crossOrigin: null
      })
      osmSource.on("tileloaderror", () => {
        this._appendDiag("MapProxy offline — fallback OSM 3857 direct")
        this._refOsm.setSource(osmFallback())
      })
    } else {
      osmSource = osmFallback()
    }

    this._refOsm = new ol.layer.Tile({ source: osmSource, visible: true })

    this._refOrtofoto = new ol.layer.Tile({
      source: new ol.source.XYZ({
        url: `${this.mapproxyUrlValue}/tms/1.0.0/ortofotoplan_3857/webmercator/{z}/{x}/{-y}.jpeg`,
        crossOrigin: null
      }),
      visible: false
    })

    // Geometriile existente — clickabile pentru a folosi centroidul lor.
    this._uatLayer = this._buildVectorLayer(this.uatGeojsonUrlValue, {
      stroke: "#6b21a8", fillRgba: "rgba(168,85,247,.08)", width: 2, dash: [4, 3]
    })
    this._parceleLayer = this._buildVectorLayer(this.parceleGeojsonUrlValue, {
      stroke: "#1d4ed8", fillRgba: "rgba(147,197,253,.15)", width: 1
    })
    this._cladiriLayer = this._buildVectorLayer(this.cladiriGeojsonUrlValue, {
      stroke: "#b45309", fillRgba: "rgba(251,191,36,.18)", width: 1
    })
    this._cgxmlLayer = this._buildVectorLayer(this.cgxmlGeojsonUrlValue, {
      stroke: "#92400e", fillRgba: "rgba(252,211,77,.25)", width: 1.5
    })

    this._refGcpSource = new ol.source.Vector()
    this._refGcpLayer  = new ol.layer.Vector({
      source: this._refGcpSource,
      style:  this._gcpStyle.bind(this),
      zIndex: 500
    })

    this._refMap = new ol.Map({
      target:   this.refMapTarget,
      controls: ol.control.defaults.defaults({ attribution: true, zoom: true }),
      view:     new ol.View({
        projection: "EPSG:3844",
        center:     [500000, 500000],
        zoom:       2,
        minZoom:    -2,
        maxZoom:    18
      }),
      layers: [
        this._refOsm, this._refOrtofoto,
        this._uatLayer, this._parceleLayer, this._cladiriLayer, this._cgxmlLayer,
        this._refGcpLayer
      ]
    })

    // Fit pe primele date încărcate (UAT sau parcele).
    this._parceleLayer?.getSource().once("featuresloadend", () => this._fitOnExistingData())
    this._uatLayer?.getSource().once("featuresloadend",     () => this._fitOnExistingData())

    this._refMap.on("singleclick", (evt) => this._onReferenceClick(evt))
    this._refMap.on("pointermove", (evt) => {
      const [x, y] = evt.coordinate
      if (this.hasRefCoordTarget) {
        this.refCoordTarget.textContent = `X: ${x.toFixed(2)} · Y: ${y.toFixed(2)}`
      }
    })

    setTimeout(() => this._refMap.updateSize(), 50)
    setTimeout(() => this._refMap.updateSize(), 500)

    this._loadReferenceMarkers()
  }

  _buildVectorLayer(url, opts) {
    if (!url) return null
    return new ol.layer.Vector({
      source: new ol.source.Vector({ url, format: new ol.format.GeoJSON() }),
      style:  new ol.style.Style({
        stroke: new ol.style.Stroke({ color: opts.stroke, width: opts.width, lineDash: opts.dash }),
        fill:   new ol.style.Fill({ color: opts.fillRgba })
      })
    })
  }

  _fitOnExistingData() {
    if (!this._refMap) return
    // Încearcă în ordine: parcele, UAT, clădiri, CGXML
    const sources = [this._parceleLayer, this._uatLayer, this._cladiriLayer, this._cgxmlLayer]
      .filter(Boolean).map(l => l.getSource())
    for (const s of sources) {
      const ext = s.getExtent()
      if (ext && isFinite(ext[0])) {
        this._refMap.getView().fit(ext, { padding: [40, 40, 40, 40], duration: 300, maxZoom: 14 })
        return
      }
    }
  }

  // ── Click handlers ────────────────────────────────────────────────────────

  _onSourceClick(evt) {
    if (!this._srcMap) return
    const [x, y] = evt.coordinate
    const px = x, py = -y
    this._pendingPx = { px, py }
    this._loadSourceMarkers()
    const tempFeat = new ol.Feature({
      geometry: new ol.geom.Point([px, -py]),
      pending:  true,
      ordinal:  this._gcps.length + 1
    })
    this._srcGcpSource.addFeature(tempFeat)
    this.leftModeTarget.textContent = `Sursă: (${Math.round(px)}, ${Math.round(py)}) — alege ținta`
    if (this.hasGcpHintTarget) {
      this.gcpHintTarget.textContent = "Acum: click pe harta dreaptă SAU click pe o geometrie existentă SAU coordonate manuale."
    }
  }

  _onReferenceClick(evt) {
    if (!this._pendingPx) {
      this.leftModeTarget.textContent = "Click ÎNTÂI pe planul vechi pentru a începe un punct."
      return
    }
    // Verifică dacă a fost click pe o geometrie existentă — folosim centroidul ei.
    let coord = evt.coordinate
    this._refMap.forEachFeatureAtPixel(evt.pixel, (feature, layer) => {
      const geom = feature.getGeometry()
      if (!geom) return
      if (geom.getType() === "Point") {
        coord = geom.getCoordinates()
        return true
      }
      // Pentru poligoane luăm interior point (mai consistent decât centroid pentru forme convexe)
      try {
        if (geom.getInteriorPoint) {
          coord = geom.getInteriorPoint().getCoordinates()
        } else {
          coord = ol.extent.getCenter(geom.getExtent())
        }
      } catch (e) {
        coord = ol.extent.getCenter(geom.getExtent())
      }
      return true
    }, { hitTolerance: 4 })

    this._submitGcp(coord[0], coord[1])
  }

  // Trigger din input manual: țintă X, Y în Stereo70 — fără click pe hartă.
  applyManualCoord() {
    if (!this._pendingPx) {
      this._setStatus("Click ÎNTÂI pe planul vechi pentru a începe un punct.", "error")
      return
    }
    const x = parseFloat(this.manualXTarget.value)
    const y = parseFloat(this.manualYTarget.value)
    if (!isFinite(x) || !isFinite(y)) {
      this._setStatus("Introdu coordonate valide pentru X și Y (Stereo70).", "error")
      return
    }
    this._submitGcp(x, y)
    this.manualXTarget.value = ""
    this.manualYTarget.value = ""
  }

  _submitGcp(wx, wy) {
    fetch(this.cpsUrlValue, {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf, Accept: "application/json" },
      body: JSON.stringify({
        gis_georef_control_point: {
          pixel_x: this._pendingPx.px,
          pixel_y: this._pendingPx.py,
          world_x: wx,
          world_y: wy
        }
      })
    })
    .then(r => r.ok ? r.json() : r.json().then(j => Promise.reject(j)))
    .then(cp => {
      this._gcps.push(cp)
      this._pendingPx = null
      this._render()
      this.leftModeTarget.textContent = "Click pe planul vechi pentru următorul punct"
      if (this.hasGcpHintTarget) {
        this.gcpHintTarget.textContent = this._gcps.length >= 3
          ? `${this._gcps.length} puncte plasate — apasă "Recalculează" sau "Finalize".`
          : `Mai sunt necesare ${3 - this._gcps.length} puncte pentru transformare.`
      }
    })
    .catch(err => this._setStatus(`Eroare la salvare GCP: ${err?.errors?.join(', ') || err}`, "error"))
  }

  // ── Load + render ────────────────────────────────────────────────────────

  async _loadGcps() {
    try {
      const r = await fetch(this.planUrlValue, {
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
      const data = await r.json()
      this._gcps = (data.control_points || []).sort((a, b) => a.ordinal - b.ordinal)
      this._render()
    } catch (e) {
      console.error("Nu pot încărca GCP-urile:", e)
    }
  }

  _render() {
    this.gcpCountTarget.textContent = String(this._gcps.length)
    this._renderList()
    this._loadSourceMarkers()
    this._loadReferenceMarkers()
  }

  _renderList() {
    this.gcpListTarget.innerHTML = this._gcps.map(cp => `
      <li class="georef-gcp">
        <span class="georef-gcp-num">${cp.ordinal + 1}</span>
        <div class="georef-gcp-coords">
          <code>px: ${Math.round(cp.pixel_x)}, ${Math.round(cp.pixel_y)}</code>
          <code>w: ${cp.world_x.toFixed(2)}, ${cp.world_y.toFixed(2)}</code>
          ${cp.residual != null ? `<span class="georef-gcp-residual">${cp.residual.toFixed(3)} m</span>` : ""}
        </div>
        <button type="button" class="btn btn-xs" data-cp-id="${cp.id}"
                data-action="click->georef-editor#deleteGcp">🗑</button>
      </li>
    `).join("")
  }

  _loadSourceMarkers() {
    if (!this._srcGcpSource) return
    this._srcGcpSource.clear()
    this._gcps.forEach((cp) => {
      const feat = new ol.Feature({
        geometry: new ol.geom.Point([cp.pixel_x, -cp.pixel_y]),
        ordinal:  cp.ordinal + 1
      })
      this._srcGcpSource.addFeature(feat)
    })
  }

  _loadReferenceMarkers() {
    if (!this._refGcpSource) return
    this._refGcpSource.clear()
    this._gcps.forEach((cp) => {
      const feat = new ol.Feature({
        geometry: new ol.geom.Point([cp.world_x, cp.world_y]),
        ordinal:  cp.ordinal + 1
      })
      this._refGcpSource.addFeature(feat)
    })
  }

  _gcpStyle(feature) {
    const isPending = feature.get("pending")
    const ord       = feature.get("ordinal") || ""
    return new ol.style.Style({
      image: new ol.style.Circle({
        radius: 9,
        fill:   new ol.style.Fill({ color: isPending ? "#facc15" : "#1d4ed8" }),
        stroke: new ol.style.Stroke({ color: "#fff", width: 2 })
      }),
      text: new ol.style.Text({
        text: String(ord),
        font: "bold 11px system-ui, sans-serif",
        fill: new ol.style.Fill({ color: "#fff" })
      })
    })
  }

  // ── Actions ──────────────────────────────────────────────────────────────

  deleteGcp(event) {
    const id = event.currentTarget.dataset.cpId
    if (!id || !confirm("Ștergi acest punct de control?")) return
    fetch(`${this.cpsUrlValue}/${id}`, {
      method: "DELETE",
      credentials: "same-origin",
      headers: { "X-CSRF-Token": this._csrf, Accept: "application/json" }
    }).then(() => {
      this._gcps = this._gcps.filter(c => c.id !== Number(id))
      this._render()
    })
  }

  async computeGeoreference() {
    if (this._gcps.length < 3) {
      this._setStatus("Sunt necesare minim 3 puncte de control.", "error")
      return
    }
    this.computeBtnTarget.disabled = true
    try {
      const r = await fetch(this.georefUrlValue, {
        method: "POST", credentials: "same-origin",
        headers: { "X-CSRF-Token": this._csrf, Accept: "application/json" }
      })
      const data = await r.json()
      if (!r.ok) throw new Error(data.error || "Eroare la calcul")
      this._gcps = (data.control_points || []).sort((a, b) => a.ordinal - b.ordinal)
      this.rmsTarget.textContent = data.rms != null ? `${data.rms.toFixed(3)} m` : "—"
      this._render()
      this._setStatus(`Afină preview calculată. RMS = ${data.rms?.toFixed(3)} m.`, "ok")
    } catch (e) {
      this._setStatus(`Eroare: ${e.message}`, "error")
    } finally {
      this.computeBtnTarget.disabled = false
    }
  }

  async finalize() {
    if (this._gcps.length < 3) {
      this._setStatus("Sunt necesare minim 3 puncte de control.", "error")
      return
    }
    const method = this.hasWarpMethodTarget ? this.warpMethodTarget.value : "auto"
    if (!confirm(`Finalize cu metoda "${method}"?\n\ngdalwarp va produce un GeoTIFF georeferențiat în Stereo70.`)) return
    this.finalizeBtnTarget.disabled = true
    this.finalizeBtnTarget.textContent = "⏳ Procesare..."
    try {
      const r = await fetch(this.finalizeUrlValue, {
        method: "POST", credentials: "same-origin",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf, Accept: "application/json" },
        body: JSON.stringify({ method })
      })
      const data = await r.json()
      if (!r.ok) throw new Error(data.error || "Eroare la warp")
      const warp = data.warp_result || {}
      this._setStatus(
        `✓ Finalize complet. Metoda: ${warp.method}. ` +
        `Warp: ${warp.width}×${warp.height} px. Planul apare acum pe harta principală.`,
        "ok"
      )
    } catch (e) {
      this._setStatus(`Eroare Finalize: ${e.message}`, "error")
    } finally {
      this.finalizeBtnTarget.disabled = false
      this.finalizeBtnTarget.textContent = "✓ Finalize (gdalwarp)"
    }
  }

  changeBase(event) {
    const choice = event.target.value
    this._refOsm?.setVisible(choice === "osm")
    this._refOrtofoto?.setVisible(choice === "ortofotoplan")
  }

  toggleLayer(event) {
    const which   = event.target.dataset.layer
    const visible = event.target.checked
    const map = {
      uat:      this._uatLayer,
      parcele:  this._parceleLayer,
      cladiri:  this._cladiriLayer,
      cgxml:    this._cgxmlLayer
    }
    map[which]?.setVisible(visible)
  }

  // Apăsare Enter în input-ul manual de coordonate
  onManualKey(event) {
    if (event.key === "Enter") {
      event.preventDefault()
      this.applyManualCoord()
    }
  }

  _setStatus(msg, kind = "info") {
    this.statusTarget.textContent = msg
    this.statusTarget.className   = `georef-status georef-status--${kind}`
  }
}
