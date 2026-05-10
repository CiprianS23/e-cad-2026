import { Controller } from "@hotwired/stimulus"

// Stereo70 (EPSG:3844) — proiecția națională română, sursa de adevăr pentru
// coordonate stocate. Hart conține tiles în Web Mercator (EPSG:3857) pentru
// compatibilitate cu OSM/Ortofotoplan; conversia se face on-the-fly.
const STEREO70 = "+proj=sterea +lat_0=46 +lon_0=25 +k=0.99975 +x_0=500000 +y_0=500000 +ellps=krass +towgs84=33.4,-146.6,-76.3,-0.359,-0.053,0.844,-0.84 +units=m +no_defs"

const PARCEL_COLORS = {
  arabil:            "#22c55e",
  pasune:            "#84cc16",
  faneata:           "#a3e635",
  vie:               "#a855f7",
  livada:            "#f97316",
  padure:            "#15803d",
  curti_constructii: "#f59e0b",
  ape:               "#38bdf8",
  neproductiv:       "#9ca3af"
}

const hexToRgba = (hex, alpha) => {
  const r = parseInt(hex.slice(1, 3), 16)
  const g = parseInt(hex.slice(3, 5), 16)
  const b = parseInt(hex.slice(5, 7), 16)
  return `rgba(${r},${g},${b},${alpha})`
}

export default class extends Controller {
  static values = {
    geojsonUrl:      String,
    cgxmlGeojsonUrl: String,
    cladiriUrl:      String,
    uatUrl:          String,
    mapproxyUrl:     String
  }

  // ── Lifecycle ────────────────────────────────────────────────────────────

  connect() {
    this._registerProjection()
    this._buildMap()
    this._buildLayers()
    this._setupPopup()
    this._loadParcele()
    this._loadCgxml()
    this._loadCladiri()
    // Notifică alte controllere (digitizare, layer-switcher) că harta e gata
    this.dispatch("ready", { detail: { map: this.map }, bubbles: true })
  }

  disconnect() {
    this.map?.setTarget(undefined)
    this.map = null
  }

  // ── Setup ────────────────────────────────────────────────────────────────

  _registerProjection() {
    if (!proj4.defs("EPSG:3844")) {
      proj4.defs("EPSG:3844", STEREO70)
    }
    if (ol.proj?.proj4) ol.proj.proj4.register(proj4)
  }

  _buildMap() {
    this.map = new ol.Map({
      target: this.element,
      controls: ol.control.defaults.defaults({ attribution: true, zoom: true }),
      view: new ol.View({
        center: ol.proj.fromLonLat([24.9, 45.75]),
        zoom: 7,
        minZoom: 4,
        maxZoom: 22
      })
    })
  }

  _buildLayers() {
    // ── Layere de bază (raster) ──
    const osm = new ol.layer.Tile({
      source: new ol.source.OSM(),
      properties: { name: "OpenStreetMap" }
    })

    this._baseLayers = { osm }

    if (this.mapproxyUrlValue) {
      this._baseLayers.ortofotoplan = new ol.layer.Tile({
        source: new ol.source.XYZ({
          url: `${this.mapproxyUrlValue}/tms/1.0.0/ortoplan/webmercator/{z}/{x}/{-y}.jpeg`,
          attributions: "© ANCPI – Ortofotoplan",
          maxZoom: 20
        }),
        properties: { name: "Ortofotoplan" }
      })
    }

    this.map.addLayer(osm)

    // ── Layere vectoriale (overlays) ──
    this.uatLayer = new ol.layer.Vector({
      source: new ol.source.Vector(),
      style: () => new ol.style.Style({
        stroke: new ol.style.Stroke({ color: "#6b21a8", width: 1.2, lineDash: [4, 3] }),
        fill:   new ol.style.Fill({ color: "rgba(168, 85, 247, 0.06)" })
      }),
      properties: { name: "uat" }
    })

    this.parcelLayer = new ol.layer.Vector({
      source: new ol.source.Vector(),
      style: this._parcelStyle.bind(this),
      properties: { name: "parcele" }
    })

    this.cladiriLayer = new ol.layer.Vector({
      source: new ol.source.Vector(),
      style: () => new ol.style.Style({
        stroke: new ol.style.Stroke({ color: "#b45309", width: 1.5 }),
        fill:   new ol.style.Fill({ color: "rgba(251, 191, 36, 0.3)" })
      }),
      properties: { name: "cladiri" }
    })

    this.cgxmlLayer = new ol.layer.Vector({
      source: new ol.source.Vector(),
      style: this._cgxmlStyle.bind(this),
      properties: { name: "cgxml" }
    })

    this._overlays = {
      uat:     this.uatLayer,
      parcele: this.parcelLayer,
      cladiri: this.cladiriLayer,
      cgxml:   this.cgxmlLayer
    }

    this.map.addLayer(this.uatLayer)
    this.map.addLayer(this.parcelLayer)
    this.map.addLayer(this.cladiriLayer)
    this.map.addLayer(this.cgxmlLayer)
  }

  // ── API public (folosit de layer-switcher prin Stimulus outlet) ──────────

  setBaseLayer(name) {
    if (!this._baseLayers) return
    Object.values(this._baseLayers).forEach(l => this.map.removeLayer(l))
    const layer = this._baseLayers[name]
    if (layer) this.map.getLayers().insertAt(0, layer)
  }

  toggleOverlay(name, visible) {
    this._overlays?.[name]?.setVisible(visible)
  }

  // ── Stiluri ──────────────────────────────────────────────────────────────

  _parcelStyle(feature) {
    const status = feature.get("status")
    const cat    = feature.get("categoria_folosinta")
    const fill   = PARCEL_COLORS[cat] || "#6b7280"
    return new ol.style.Style({
      stroke: new ol.style.Stroke({
        color:    status === "litigiu" ? "#dc2626" : "#1d4ed8",
        width:    status === "litigiu" ? 2.5 : 1.5,
        lineDash: status === "inactiv" ? [6, 4] : null
      }),
      fill: new ol.style.Fill({ color: hexToRgba(fill, 0.35) })
    })
  }

  _cgxmlStyle(feature) {
    const isBuilding = feature.get("entity_type") === "building"
    return new ol.style.Style({
      stroke: new ol.style.Stroke({
        color: isBuilding ? "#b91c1c" : "#92400e",
        width: isBuilding ? 1.5 : 2
      }),
      fill: new ol.style.Fill({
        color: isBuilding ? "rgba(252, 165, 165, 0.45)" : "rgba(252, 211, 77, 0.45)"
      })
    })
  }

  // ── Popup overlay (echivalent Leaflet bindPopup) ─────────────────────────

  _setupPopup() {
    const el = document.createElement("div")
    el.className = "ol-popup-content"
    this._popupEl = el

    this._popup = new ol.Overlay({
      element: el,
      autoPan: { animation: { duration: 200 } },
      positioning: "bottom-center",
      offset: [0, -12],
      stopEvent: true
    })
    this.map.addOverlay(this._popup)

    this.map.on("singleclick", (evt) => {
      let html = null
      this.map.forEachFeatureAtPixel(evt.pixel, (feature, layer) => {
        const layerName = layer?.get("name")
        if (layerName === "parcele")  html = this._parcelPopupHtml(feature)
        if (layerName === "cladiri")  html = this._cladirePopupHtml(feature)
        if (layerName === "cgxml")    html = this._cgxmlPopupHtml(feature)
        if (layerName === "uat")      html = this._uatPopupHtml(feature)
        return html ? true : undefined
      }, { hitTolerance: 3 })

      if (html) {
        el.innerHTML = html
        this._popup.setPosition(evt.coordinate)
      } else {
        this._popup.setPosition(undefined)
      }
    })

    this.map.on("pointermove", (evt) => {
      if (evt.dragging) return
      const hit = this.map.hasFeatureAtPixel(evt.pixel)
      this.map.getTargetElement().style.cursor = hit ? "pointer" : ""
    })
  }

  _parcelPopupHtml(f) {
    const supraf = f.get("suprafata_mp") ? `${Number(f.get("suprafata_mp")).toLocaleString("ro")} mp` : "—"
    return `
      <div class="map-popup">
        <strong>${f.get("numar_cadastral") || "—"}</strong>
        <dl>
          <dt>Categorie</dt><dd>${f.get("categoria_folosinta") || "—"}</dd>
          <dt>Suprafață</dt><dd>${supraf}</dd>
          <dt>Județ</dt><dd>${f.get("judet") || "—"}</dd>
          <dt>Localitate</dt><dd>${f.get("localitate") || "—"}</dd>
          <dt>Proprietar</dt><dd>${f.get("proprietar") || "—"}</dd>
          <dt>Status</dt><dd><span class="badge badge-${f.get("status")}">${f.get("status")}</span></dd>
        </dl>
        <a href="/parcele_cadastrale/${f.get("id")}" class="btn btn-sm btn-primary" style="margin-top:6px">Detalii</a>
      </div>
    `
  }

  _cladirePopupHtml(f) {
    const supraf = f.get("suprafata_construita_mp")
      ? `${Number(f.get("suprafata_construita_mp")).toLocaleString("ro")} mp` : "—"
    return `
      <div class="map-popup">
        <strong>${f.get("numar_cadastral") || "—"}</strong>
        <dl>
          <dt>Destinație</dt><dd>${f.get("destinatie") || "—"}</dd>
          <dt>Regim înălțime</dt><dd>${f.get("regim_inaltime") || "—"}</dd>
          <dt>Suprafață</dt><dd>${supraf}</dd>
          <dt>Județ</dt><dd>${f.get("judet") || "—"}</dd>
          <dt>Localitate</dt><dd>${f.get("localitate") || "—"}</dd>
          <dt>Proprietar</dt><dd>${f.get("proprietar") || "—"}</dd>
        </dl>
        <a href="/cladiri_cadastrale/${f.get("id")}" class="btn btn-sm btn-primary" style="margin-top:6px">Detalii</a>
      </div>
    `
  }

  _cgxmlPopupHtml(f) {
    const isBuilding = f.get("entity_type") === "building"
    const title      = isBuilding ? `Construcție #${f.get("buildno") ?? f.get("id")}` : "Imobil"
    const filename   = f.get("filename") || "—"
    const fileLink   = f.get("file_description_id")
      ? `<a href="/cgxml_files/${f.get("file_description_id")}" target="_blank">${filename}</a>` : filename
    const mp = (v) => v != null ? `${Number(v).toLocaleString("ro-RO", { maximumFractionDigits: 2 })} mp` : "—"
    return `
      <div class="map-popup cgxml-popup">
        <div class="popup-title">${title}</div>
        <table class="popup-table">
          <tr><th>Fișier</th><td>${fileLink}</td></tr>
          <tr><th>Versiune</th><td>${f.get("fileversion") || "—"}</td></tr>
          <tr><th>Suprafață</th><td>${mp(f.get("measuredarea"))}</td></tr>
          ${f.get("cadgenno") ? `<tr><th>Nr. cadastral</th><td>${f.get("cadgenno")}</td></tr>` : ""}
        </table>
      </div>
    `
  }

  _uatPopupHtml(f) {
    return `<div class="map-popup"><strong>${f.get("name") || f.get("nat_code") || "UAT"}</strong></div>`
  }

  // ── Încărcare date GeoJSON ───────────────────────────────────────────────

  async _loadParcele() {
    try {
      const res  = await fetch(this.geojsonUrlValue)
      const data = await res.json()
      this._addGeoJSON(this.parcelLayer, data)
      this._fitToLayer(this.parcelLayer)
      this._loadUatForCenter(this.parcelLayer)
    } catch (e) {
      console.warn("Nu s-au putut încărca parcelele:", e)
    }
  }

  async _loadCgxml() {
    if (!this.cgxmlGeojsonUrlValue) return
    try {
      const res  = await fetch(this.cgxmlGeojsonUrlValue)
      const data = await res.json()
      this._addGeoJSON(this.cgxmlLayer, data)
      if (this.parcelLayer.getSource().getFeatures().length === 0) {
        this._fitToLayer(this.cgxmlLayer)
        this._loadUatForCenter(this.cgxmlLayer)
      }
    } catch (e) {
      console.warn("Nu s-au putut încărca imobilele CGXML:", e)
    }
  }

  async _loadCladiri() {
    if (!this.cladiriUrlValue) return
    try {
      const res  = await fetch(this.cladiriUrlValue)
      const data = await res.json()
      this._addGeoJSON(this.cladiriLayer, data)
    } catch (e) {
      console.warn("Nu s-au putut încărca clădirile:", e)
    }
  }

  async _loadUatForCenter(layer) {
    if (!this.uatUrlValue) return
    const features = layer.getSource().getFeatures()
    if (features.length === 0) return
    const extent = layer.getSource().getExtent()
    const cx = (extent[0] + extent[2]) / 2
    const cy = (extent[1] + extent[3]) / 2
    const [lng, lat] = ol.proj.toLonLat([cx, cy])
    try {
      const res  = await fetch(`${this.uatUrlValue}?lat=${lat}&lng=${lng}`)
      const data = await res.json()
      this.uatLayer.getSource().clear()
      this._addGeoJSON(this.uatLayer, data)
    } catch (e) {
      console.warn("Nu s-a putut încărca limita UAT:", e)
    }
  }

  // ── Utilitare ─────────────────────────────────────────────────────────────

  _addGeoJSON(layer, data) {
    const features = new ol.format.GeoJSON().readFeatures(data, {
      dataProjection:    "EPSG:4326",
      featureProjection: "EPSG:3857"
    })
    layer.getSource().addFeatures(features)
  }

  _fitToLayer(layer) {
    const features = layer.getSource().getFeatures()
    if (features.length === 0) return
    const extent = layer.getSource().getExtent()
    this.map.getView().fit(extent, { padding: [40, 40, 40, 40], maxZoom: 18, duration: 300 })
  }
}
