import { Controller } from "@hotwired/stimulus"

// Georef Editor — ecran dual-viewport pentru plasare GCP (puncte de control).
// Pane STÂNGA: imaginea sursă, randată via ol.source.ImageStatic într-un
//   "fake CRS" pixel (0..W × 0..H). Click pe imagine = punct sursă (pixel_x, pixel_y).
// Pane DREAPTA: harta de referință în EPSG:3844 (Stereo70) cu ortofoto/OSM
//   + parcele existente. Click pe hartă = punct țintă (world_x, world_y).
//
// Workflow:
//   1. Click stânga → marker temporar pe imagine
//   2. Click dreapta → POST /control_points → marker permanent pe ambele pane
//   3. Repetă pentru cel puțin 3 GCP-uri
//   4. Click "Recalculează" → POST /georeference → afișează RMS și reziduurile
export default class extends Controller {
  static targets = [
    "srcMap", "refMap", "gcpList", "gcpCount", "rms",
    "leftMode", "rightMode", "srcCoord", "refCoord", "srcDims",
    "status", "computeBtn", "gcpHint"
  ]
  static values = {
    planId:              Number,
    rasterUrl:           String,
    originalWidth:       Number,
    originalHeight:      Number,
    cpsUrl:              String,
    georefUrl:           String,
    planUrl:             String,
    cgxmlGeojsonUrl:     String,
    parceleGeojsonUrl:   String,
    mapproxyUrl:         String
  }

  connect() {
    this._csrf       = document.querySelector('meta[name="csrf-token"]')?.content
    this._pendingPx  = null   // {px, py} setat la primul click pe sursă, golit după închiderea perechii
    this._gcps       = []     // GCP-uri persistate (server-side)
    this._registerProjection()

    // Detectează dimensiunile imaginii dacă nu sunt setate
    this._ensureDimensions().then(() => {
      this._buildSourceMap()
      this._buildReferenceMap()
      this._loadGcps()
    })
  }

  // ── Setup ────────────────────────────────────────────────────────────────

  _registerProjection() {
    if (!proj4.defs("EPSG:3844")) {
      proj4.defs("EPSG:3844",
        "+proj=sterea +lat_0=46 +lon_0=25 +k=0.99975 +x_0=500000 +y_0=500000 " +
        "+ellps=krass +towgs84=33.4,-146.6,-76.3,-0.359,-0.053,0.844,-0.84 +units=m +no_defs")
    }
    if (ol.proj?.proj4) ol.proj.proj4.register(proj4)
    // Sistem pixel pentru imaginea sursă: identitate (m=px)
    // Definim o "proiecție" custom doar pentru pane-ul stâng.
    if (!ol.proj.get("PLAN-PIXEL")) {
      const pixelProj = new ol.proj.Projection({
        code:    "PLAN-PIXEL",
        units:   "pixels",
        extent:  [0, 0, this.originalWidthValue || 10000, this.originalHeightValue || 10000],
        axisOrientation: "enu"  // x→ est, y→ nord (vom inversa Y la afișare)
      })
      ol.proj.addProjection(pixelProj)
    }
  }

  async _ensureDimensions() {
    if (this.originalWidthValue > 0 && this.originalHeightValue > 0) return
    if (!this.rasterUrlValue) return
    return new Promise((resolve) => {
      const img = new Image()
      img.crossOrigin = "anonymous"
      img.onload = async () => {
        this.originalWidthValue  = img.naturalWidth
        this.originalHeightValue = img.naturalHeight
        if (this.hasSrcDimsTarget) {
          this.srcDimsTarget.textContent = `${img.naturalWidth} × ${img.naturalHeight} px`
        }
        // Persistă dimensiunile pe plan (PATCH)
        await fetch(this.planUrlValue, {
          method: "PATCH",
          credentials: "same-origin",
          headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf, Accept: "application/json" },
          body: JSON.stringify({ gis_georef_plan: {
            original_width: img.naturalWidth, original_height: img.naturalHeight
          }})
        })
        resolve()
      }
      img.onerror = () => resolve()
      img.src = this.rasterUrlValue
    })
  }

  _buildSourceMap() {
    if (!this.hasSrcMapTarget) return
    const W = this.originalWidthValue
    const H = this.originalHeightValue
    if (!W || !H) {
      this.srcMapTarget.innerHTML = "<p class='georef-empty'>Imaginea nu se poate afișa (dimensiuni necunoscute).</p>"
      return
    }
    // Coordonate pixel: (0,0) sus-stânga, (W,H) jos-dreapta. OL by default
    // are y crescător în sus → vom folosi extent [0, -H, W, 0] și inversăm y la afișare.
    const extent = [0, -H, W, 0]

    this._srcImageLayer = new ol.layer.Image({
      source: new ol.source.ImageStatic({
        url:           this.rasterUrlValue,
        imageExtent:   extent,
        projection:    "PLAN-PIXEL",
        crossOrigin:   "anonymous"
      })
    })

    this._srcGcpSource = new ol.source.Vector()
    this._srcGcpLayer  = new ol.layer.Vector({
      source: this._srcGcpSource,
      style:  this._gcpStyle.bind(this, "src"),
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
      this.srcCoordTarget.textContent = `Pixel: ${Math.round(x)}, ${Math.round(-y)}`
    })
  }

  _buildReferenceMap() {
    if (!this.hasRefMapTarget) return
    // Setăm extent-ul Stereo70 pentru România
    const proj = ol.proj.get("EPSG:3844")
    if (proj && !proj.getExtent()) proj.setExtent([120000, 250000, 900000, 800000])

    this._refOsm = new ol.layer.Tile({
      source: new ol.source.OSM(),
      visible: true
    })
    this._refOrtofoto = new ol.layer.Tile({
      source: new ol.source.XYZ({
        url: `${this.mapproxyUrlValue}/tms/1.0.0/ortofotoplan_3857/webmercator/{z}/{x}/{-y}.jpeg`
      }),
      visible: false
    })

    this._parceleSrc = new ol.source.Vector({
      url:    this.parceleGeojsonUrlValue,
      format: new ol.format.GeoJSON()
    })
    this._parceleLayer = new ol.layer.Vector({
      source: this._parceleSrc,
      style:  new ol.style.Style({
        stroke: new ol.style.Stroke({ color: "#1d4ed8", width: 1.2 }),
        fill:   new ol.style.Fill({ color: "rgba(147, 197, 253, 0.15)" })
      })
    })

    this._refGcpSource = new ol.source.Vector()
    this._refGcpLayer  = new ol.layer.Vector({
      source: this._refGcpSource,
      style:  this._gcpStyle.bind(this, "ref"),
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
      layers: [this._refOsm, this._refOrtofoto, this._parceleLayer, this._refGcpLayer]
    })

    // Fit pe parcelele existente după ce se încarcă
    this._parceleSrc.once("featuresloadend", () => {
      const ext = this._parceleSrc.getExtent()
      if (ext && isFinite(ext[0])) {
        this._refMap.getView().fit(ext, { padding: [40, 40, 40, 40], duration: 300, maxZoom: 14 })
      }
    })

    this._refMap.on("singleclick", (evt) => this._onReferenceClick(evt))
    this._refMap.on("pointermove", (evt) => {
      const [x, y] = evt.coordinate
      this.refCoordTarget.textContent = `X: ${x.toFixed(2)} · Y: ${y.toFixed(2)}`
    })
  }

  // ── Click handlers ────────────────────────────────────────────────────────

  _onSourceClick(evt) {
    const [x, y] = evt.coordinate
    // Convertim coordonata OL (Y negativ) la pixel imagine (Y pozitiv)
    const px = x
    const py = -y
    this._pendingPx = { px, py }
    // Marker temporar pe pane stâng (galben — pending)
    this._srcGcpSource.clear()
    this._loadSourceMarkers()
    const tempFeat = new ol.Feature({
      geometry: new ol.geom.Point([px, -py]),
      pending:  true,
      ordinal:  this._gcps.length + 1
    })
    this._srcGcpSource.addFeature(tempFeat)
    this.leftModeTarget.textContent = `Sursă: (${Math.round(px)}, ${Math.round(py)}) — click pe harta de referință`
    this.gcpHintTarget.textContent  = "Acum click pe poziția corespunzătoare în harta de referință (Stereo70)."
  }

  _onReferenceClick(evt) {
    if (!this._pendingPx) {
      this.leftModeTarget.textContent = "Click ÎNTÂI pe planul vechi pentru a începe un punct."
      return
    }
    const [wx, wy] = evt.coordinate

    // POST către server pentru a persista GCP-ul
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
    .then(r => r.ok ? r.json() : Promise.reject(r))
    .then(cp => {
      this._gcps.push(cp)
      this._pendingPx = null
      this._render()
      this.leftModeTarget.textContent = "Click pe planul vechi pentru următorul punct"
      this.gcpHintTarget.textContent  = this._gcps.length >= 3
        ? `${this._gcps.length} puncte plasate — apasă "Recalculează" pentru a aplica transformarea.`
        : `Mai sunt necesare ${3 - this._gcps.length} puncte pentru transformare.`
    })
    .catch(err => this._setStatus(`Eroare la salvare GCP: ${err.status || ''}`, "error"))
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
          ${cp.residual != null ? `<span class="georef-gcp-residual" title="Reziduu la fit">${cp.residual.toFixed(3)} m</span>` : ""}
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

  _gcpStyle(_pane, feature) {
    const isPending = feature.get("pending")
    const ord       = feature.get("ordinal") || ""
    return new ol.style.Style({
      image: new ol.style.Circle({
        radius: 8,
        fill:   new ol.style.Fill({ color: isPending ? "#facc15" : "#1d4ed8" }),
        stroke: new ol.style.Stroke({ color: "#fff", width: 2 })
      }),
      text: new ol.style.Text({
        text:    String(ord),
        font:    "bold 11px system-ui, sans-serif",
        fill:    new ol.style.Fill({ color: "#fff" })
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
        method: "POST",
        credentials: "same-origin",
        headers: { "X-CSRF-Token": this._csrf, Accept: "application/json" }
      })
      const data = await r.json()
      if (!r.ok) throw new Error(data.error || "Eroare la calcul")
      this._gcps = (data.control_points || []).sort((a, b) => a.ordinal - b.ordinal)
      this.rmsTarget.textContent = data.rms != null ? `${data.rms.toFixed(3)} m` : "—"
      this._render()
      this._setStatus(`Georeferențiere calculată. RMS = ${data.rms?.toFixed(3)} m. Planul va apărea ca layer pe harta principală.`, "ok")
    } catch (e) {
      this._setStatus(`Eroare: ${e.message}`, "error")
    } finally {
      this.computeBtnTarget.disabled = false
    }
  }

  changeBase(event) {
    const choice = event.target.value
    this._refOsm.setVisible(choice === "osm")
    this._refOrtofoto.setVisible(choice === "ortofotoplan")
  }

  _setStatus(msg, kind = "info") {
    this.statusTarget.textContent = msg
    this.statusTarget.className   = `georef-status georef-status--${kind}`
  }
}
