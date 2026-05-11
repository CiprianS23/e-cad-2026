import { Controller } from "@hotwired/stimulus"

// Stereo70 (EPSG:3844) — proiecția națională română, sursa de adevăr pentru
// coordonate stocate. Hart conține tiles în Web Mercator (EPSG:3857) pentru
// compatibilitate cu OSM/Ortofotoplan; conversia se face on-the-fly.
const STEREO70 = "+proj=sterea +lat_0=46 +lon_0=25 +k=0.99975 +x_0=500000 +y_0=500000 +ellps=krass +towgs84=33.4,-146.6,-76.3,-0.359,-0.053,0.844,-0.84 +units=m +no_defs"

// Prag rezoluție (metri/pixel) peste care etichetele se ascund.
// Convenție: scale = resolution × 96 dpi × 39.37 inch/m ≈ resolution × 3779.5
// Deci pragul 1:10000 corespunde la ~2.645 m/px.
const LABEL_MAX_RESOLUTION         = 2.645   // ≈ scara 1:10 000
const LABEL_MAX_RESOLUTION_CLADIRI = 2.645   // ≈ scara 1:10 000

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
    // Re-render etichete la fiecare pan/zoom — recalculează poziția să
    // rămână în viewport chiar și când poligonul iese parțial din vedere.
    this.map.on("moveend", () => {
      this.parcelLabelsLayer?.changed()
      this.cladiriLabelsLayer?.changed()
      this.cgxmlLabelsLayer?.changed()
    })
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
    // Setăm extent-ul real al Stereo 70 pentru România ca OL să poată face
    // reproject corect al tile-urilor 3857 (OSM, Ortofotoplan) în view 3844.
    const proj = ol.proj.get("EPSG:3844")
    if (proj && !proj.getExtent()) {
      proj.setExtent([120000, 250000, 900000, 800000])
    }
  }

  _buildMap() {
    // VIEW în Stereo 70 — toate coordonatele cursor / vertecși sunt direct în
    // EPSG:3844 (metri reali România), fără round-trip prin Web Mercator.
    // Tile-urile OSM/Ortofotoplan sunt în 3857; OL le reproject automat pe-ndelete.
    this.map = new ol.Map({
      target: this.element,
      controls: ol.control.defaults.defaults({ attribution: true, zoom: true }),
      view: new ol.View({
        projection: "EPSG:3844",
        center:     [500000, 500000],  // aprox. centru România în Stereo70
        zoom:       2,
        minZoom:    -2,
        maxZoom:    18
      })
    })
  }

  _buildLayers() {
    // ── Layere de bază (raster) ── în Stereo 70 nativ via MapProxy
    // Grid stereo70: origin NW (120000, 800000), 15 niveluri de rezoluție.
    const stereoGrid = new ol.tilegrid.TileGrid({
      origin:      [120000, 800000],
      resolutions: [3072, 1536, 768, 384, 192, 96, 48, 24, 12, 6, 3, 1.5, 0.75, 0.375, 0.1875],
      tileSize:    [256, 256],
      extent:      [120000, 250000, 900000, 800000]
    })

    this._baseLayers = {}

    // Fallback OSM 3857 (reproject OL) — folosit dacă MapProxy nu răspunde
    const osmFallback = () => new ol.layer.Tile({
      source: new ol.source.OSM(),
      properties: { name: "OpenStreetMap (3857 reproject)" }
    })

    if (this.mapproxyUrlValue) {
      const osmSrc = new ol.source.XYZ({
        url:          `${this.mapproxyUrlValue}/tms/1.0.0/osm/stereo70/{z}/{x}/{-y}.png`,
        projection:   "EPSG:3844",
        tileGrid:     stereoGrid,
        attributions: "© OpenStreetMap contributors (via MapProxy / Stereo70)"
      })
      this._baseLayers.osm = new ol.layer.Tile({
        source: osmSrc,
        properties: { name: "OpenStreetMap (Stereo70)" }
      })
      // La prima eroare de tile (MapProxy offline) → comutăm pe OSM 3857
      const onErr = () => {
        osmSrc.un("tileloaderror", onErr)
        const isActive = this.map.getLayers().getArray().includes(this._baseLayers.osm)
        if (isActive) this.map.removeLayer(this._baseLayers.osm)
        this._baseLayers.osm = osmFallback()
        if (isActive) this.map.getLayers().insertAt(0, this._baseLayers.osm)
        console.warn("MapProxy indisponibil — fallback OSM 3857 (reproject).")
      }
      osmSrc.on("tileloaderror", onErr)

      const ortoSrc = new ol.source.XYZ({
        url:          `${this.mapproxyUrlValue}/tms/1.0.0/ortoplan/stereo70/{z}/{x}/{-y}.jpeg`,
        projection:   "EPSG:3844",
        tileGrid:     stereoGrid,
        attributions: "© ANCPI – Ortofotoplan (Stereo70)"
      })
      this._baseLayers.ortofotoplan = new ol.layer.Tile({
        source: ortoSrc,
        properties: { name: "Ortofotoplan (Stereo70)" }
      })
    } else {
      this._baseLayers.osm = osmFallback()
    }

    this.map.addLayer(this._baseLayers.osm)

    // ── Layere vectoriale (overlays) ──
    // Store dinamic pentru config-ul aplicat de Layer Manager (overrides peste default-uri).
    this._layerConfig = this._layerConfig || {}

    this.uatLayer = new ol.layer.Vector({
      source: new ol.source.Vector(),
      style: () => {
        const cfg = this._layerConfig?.uat || {}
        return new ol.style.Style({
          stroke: new ol.style.Stroke({
            color:    cfg.stroke_color || "#6b21a8",
            width:    cfg.stroke_width || 1.2,
            lineDash: this._dashArray(cfg.stroke_dash, "dashed")
          }),
          fill: new ol.style.Fill({
            color: this._toRgba(cfg.fill_color || "rgba(168, 85, 247, 0.06)", 1)
          })
        })
      },
      properties: { name: "uat" }
    })

    this.parcelLayer = new ol.layer.Vector({
      source: new ol.source.Vector(),
      style: this._parcelStyle.bind(this),
      properties: { name: "parcele" }
    })

    this.cladiriLayer = new ol.layer.Vector({
      source: new ol.source.Vector(),
      style:  this._cladireStyle.bind(this),
      properties: { name: "cladiri" }
    })

    this.cgxmlLayer = new ol.layer.Vector({
      source: new ol.source.Vector(),
      style: this._cgxmlStyle.bind(this),
      properties: { name: "cgxml" }
    })

    // Layere dedicate pentru ETICHETE (nr cadastral + suprafață) — share source
    // cu layer-ele de bază dar randate la zIndex 1200 ca să fie DEASUPRA
    // overlay-urilor (audit, topology, edit-vertices) care altfel acoperă textul.
    this.parcelLabelsLayer = new ol.layer.Vector({
      source:     this.parcelLayer.getSource(),
      style:      this._parcelLabelStyle.bind(this),
      zIndex:     1200,
      properties: { name: "parcele-labels" }
    })
    this.cladiriLabelsLayer = new ol.layer.Vector({
      source:     this.cladiriLayer.getSource(),
      style:      this._cladireLabelStyle.bind(this),
      zIndex:     1200,
      properties: { name: "cladiri-labels" }
    })
    this.cgxmlLabelsLayer = new ol.layer.Vector({
      source:     this.cgxmlLayer.getSource(),
      style:      this._cgxmlLabelStyle.bind(this),
      zIndex:     1200,
      properties: { name: "cgxml-labels" }
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
    this.map.addLayer(this.parcelLabelsLayer)
    this.map.addLayer(this.cladiriLabelsLayer)
    this.map.addLayer(this.cgxmlLabelsLayer)
  }

  // ── API public — folosit de layer-manager prin Stimulus outlet ────────────

  setBaseLayer(name) {
    if (!this._baseLayers) return
    Object.values(this._baseLayers).forEach(l => this.map.removeLayer(l))
    const layer = this._baseLayers[name]
    if (layer) this.map.getLayers().insertAt(0, layer)
  }

  toggleOverlay(name, visible) {
    this._overlays?.[name]?.setVisible(visible)
    // Sincronizăm vizibilitatea label-urilor cu cea a layer-ului
    if (name === "parcele") this.parcelLabelsLayer?.setVisible(visible)
    if (name === "cladiri") this.cladiriLabelsLayer?.setVisible(visible)
    if (name === "cgxml")   this.cgxmlLabelsLayer?.setVisible(visible)
  }

  // Layer Manager API — aplicăm un set de proprietăți de stil per layer cunoscut.
  // `config` = { visible, locked, opacity, stroke_color, fill_color,
  //              stroke_width, stroke_dash, z_index, color_by_category }
  // Toate proprietățile sunt opționale.
  applyLayerConfig(layerKey, config) {
    if (!config) return
    if (!this._layerConfig) this._layerConfig = {}
    // Merge cu config existent (update incremental, nu overwrite total)
    this._layerConfig[layerKey] = { ...(this._layerConfig[layerKey] || {}), ...config }
    const merged = this._layerConfig[layerKey]
    const layer  = this._resolveLayer(layerKey)
    if (!layer) return

    if (typeof merged.visible  === "boolean") layer.setVisible(merged.visible)
    if (typeof merged.opacity  === "number")  layer.setOpacity(merged.opacity)
    if (typeof merged.z_index  === "number")  layer.setZIndex(merged.z_index)

    // Sincronizare label-uri cu layer-ul părinte pentru vizibilitate "implicită"
    // (rămâne sub controlul explicit al layer-ului dedicat *_labels din DB).
    layer.changed()
  }

  // Întoarce extent-ul (bbox) features-urilor unui layer — pentru "zoom la layer".
  getLayerExtent(layerKey) {
    const layer = this._resolveLayer(layerKey)
    if (!layer || !layer.getSource) return null
    const src = layer.getSource()
    if (!src || typeof src.getExtent !== "function") return null
    const ext = src.getExtent()
    if (!ext || !isFinite(ext[0])) return null
    return ext
  }

  zoomToLayer(layerKey, padding = 60) {
    const ext = this.getLayerExtent(layerKey)
    if (!ext) return false
    this.map.getView().fit(ext, { duration: 400, padding: [padding, padding, padding, padding] })
    return true
  }

  // Întoarce true dacă layer-ul e marcat ca "locked" (editarea blocată din UI).
  // Folosit de digitizare_controller pentru a refuza editarea pe layere blocate.
  isLayerLocked(layerKey) {
    return !!this._layerConfig?.[layerKey]?.locked
  }

  _resolveLayer(key) {
    const map = {
      uat:            this.uatLayer,
      parcele:        this.parcelLayer,
      cladiri:        this.cladiriLayer,
      cgxml:          this.cgxmlLayer,
      parcele_labels: this.parcelLabelsLayer,
      cladiri_labels: this.cladiriLabelsLayer,
      cgxml_labels:   this.cgxmlLabelsLayer
    }
    return map[key]
  }

  setDigitizing(active) {
    this._digitizing = active
    if (active) this._popup?.setPosition(undefined)
  }

  // ── Selecție feature (pentru Edit mode) ────────────────────────────────

  _setSelectedFeature(sel) {
    if (!this._selectionLayer) {
      this._selectionLayer = new ol.layer.Vector({
        source: new ol.source.Vector(),
        style:  () => new ol.style.Style({
          stroke: new ol.style.Stroke({ color: "#16a34a", width: 4 }),
          fill:   new ol.style.Fill({ color: "rgba(34, 197, 94, 0.15)" })
        }),
        zIndex: 999
      })
      this.map.addLayer(this._selectionLayer)
    }
    this._selectionLayer.getSource().clear()
    if (sel) {
      // Clonăm geometry pentru un layer de overlay (nu mutăm originalul)
      const overlay = new ol.Feature({ geometry: sel.feature.getGeometry().clone() })
      this._selectionLayer.getSource().addFeature(overlay)
    }
    this._selected = sel
    this.dispatch(sel ? "feature-selected" : "feature-deselected", {
      detail: sel,
      bubbles: true
    })
  }

  clearSelection() { this._setSelectedFeature(null) }

  // Zoom contextual: extinde extent-ul ×3.5 pentru a păstra zona vecină
  // vizibilă în jurul poligonului selectat.
  _zoomToFeature(feature) {
    const geom = feature.getGeometry?.()
    if (!geom) return
    const e = geom.getExtent()
    if (!e || !isFinite(e[0])) return
    const cx = (e[0] + e[2]) / 2
    const cy = (e[1] + e[3]) / 2
    const halfW = Math.max((e[2] - e[0]) / 2, 5)  // min 5 m pentru entități mici
    const halfH = Math.max((e[3] - e[1]) / 2, 5)
    const k = 5
    const padded = [cx - halfW * k, cy - halfH * k, cx + halfW * k, cy + halfH * k]
    this.map.getView().fit(padded, { duration: 400 })
  }

  // ── Stiluri ──────────────────────────────────────────────────────────────

  _parcelStyle(feature) {
    const status   = feature.get("status")
    const cat      = feature.get("categoria_folosinta")
    const cfg      = this._layerConfig?.parcele || {}
    const useCat   = cfg.color_by_category !== false  // implicit: colorare pe categorie ON
    const baseFill = useCat ? (PARCEL_COLORS[cat] || "#6b7280") : (cfg.fill_color || "#ffffff")
    const strokeC  = status === "litigiu" ? "#dc2626" : (cfg.stroke_color || "#1d4ed8")
    const strokeW  = status === "litigiu" ? 2.5 : (cfg.stroke_width || 1.5)
    return new ol.style.Style({
      stroke: new ol.style.Stroke({
        color:    strokeC,
        width:    strokeW,
        lineDash: this._dashArray(cfg.stroke_dash, status === "inactiv" ? "dashed" : null)
      }),
      fill: new ol.style.Fill({ color: this._toRgba(baseFill, useCat ? 0.35 : 1) })
    })
  }

  // Convertește numele de pattern dash în array OL (sau null pentru continuă).
  _dashArray(pattern, fallback) {
    const p = pattern || fallback
    switch (p) {
      case "dashed":  return [6, 4]
      case "dotted":  return [2, 3]
      case "dash-dot": return [6, 3, 1, 3]
      case "solid":
      default:        return null
    }
  }

  // Acceptă atât #RRGGBB cât și rgba(...) — întoarce string color valid CSS/OL.
  _toRgba(color, alpha) {
    if (!color)                                  return `rgba(107,114,128,${alpha ?? 1})`
    if (color === "transparent")                 return "rgba(0,0,0,0)"
    if (color.startsWith("rgba"))                return color
    if (color.startsWith("rgb("))                return color.replace("rgb(", "rgba(").replace(")", `,${alpha ?? 1})`)
    if (color.startsWith("#") && color.length === 7) return hexToRgba(color, alpha ?? 1)
    return color
  }

  // Style pentru layer-ul de etichete (separat ca să fie deasupra
  // overlay-urilor de audit/topology/edit-vertices). Suprafața recalculată
  // din geom curentă → update dinamic la edit.
  _parcelLabelStyle(feature, resolution) {
    if (this._layerConfig?.parcele_labels?.visible === false) return null
    if (resolution > LABEL_MAX_RESOLUTION) return null
    const nrCad = feature.get("numar_cadastral") || ""
    const geom  = feature.getGeometry()
    if (!geom) return null
    const area  = Math.round(geom.getArea())
    const label = nrCad && area != null ? `${nrCad}\n${area} mp` : (nrCad || (area != null ? `${area} mp` : ""))
    if (!label) return null
    const labelPos = this._computeLabelPosition(geom)
    if (!labelPos) return null  // geometria nu intersectează viewport-ul
    return new ol.style.Style({
      geometry: new ol.geom.Point(labelPos),
      text: new ol.style.Text({
        text:      label,
        font:      "600 12px system-ui, sans-serif",
        fill:      new ol.style.Fill({ color: "#1a1a2e" }),
        stroke:    new ol.style.Stroke({ color: "#fff", width: 4 }),
        textAlign: "center",
        overflow:  true
      })
    })
  }

  // Returnează interior point al unui Polygon SAU MultiPolygon. Standard
  // OL: getInteriorPoint() există doar pe Polygon — pentru MultiPolygon
  // apelăm pe primul sub-poligon.
  _geomInteriorPoint(geom) {
    const type = geom.getType()
    if (type === "Polygon") return geom.getInteriorPoint().getCoordinates()
    if (type === "MultiPolygon") {
      const polys = geom.getPolygons()
      if (polys.length === 0) return ol.extent.getCenter(geom.getExtent())
      return polys[0].getInteriorPoint().getCoordinates()
    }
    return ol.extent.getCenter(geom.getExtent())
  }

  // Calculează poziția optimă pentru etichetă astfel încât să rămână în
  // viewport chiar și când poligonul se extinde dincolo de zona vizibilă
  // (la zoom-in puternic).
  _computeLabelPosition(geom) {
    if (!this.map) return this._geomInteriorPoint(geom)
    const viewExt = this.map.getView().calculateExtent(this.map.getSize())
    const polyExt = geom.getExtent()
    if (!ol.extent.intersects(polyExt, viewExt)) return null

    const interior = this._geomInteriorPoint(geom)
    if (ol.extent.containsCoordinate(viewExt, interior)) return interior

    // Centrul intersecției bbox-urilor — în general în viewport
    const inter = ol.extent.getIntersection(polyExt, viewExt)
    if (ol.extent.isEmpty(inter)) return null
    const c = ol.extent.getCenter(inter)
    // Dacă centrul nu e în poligon, aproximăm cu cel mai apropiat punct de pe boundary
    if (geom.intersectsCoordinate(c)) return c
    return geom.getClosestPoint(c)
  }

  _cladireStyle(feature) {
    const cfg = this._layerConfig?.cladiri || {}
    return new ol.style.Style({
      stroke: new ol.style.Stroke({
        color:    cfg.stroke_color || "#b45309",
        width:    cfg.stroke_width || 1.5,
        lineDash: this._dashArray(cfg.stroke_dash, null)
      }),
      fill: new ol.style.Fill({ color: this._toRgba(cfg.fill_color || "rgba(251, 191, 36, 0.3)", 1) })
    })
  }

  _cladireLabelStyle(feature, resolution) {
    if (this._layerConfig?.cladiri_labels?.visible === false) return null
    if (resolution > LABEL_MAX_RESOLUTION_CLADIRI) return null
    const nrCad = feature.get("numar_cadastral") || ""
    const geom  = feature.getGeometry()
    if (!geom) return null
    const area  = Math.round(geom.getArea())
    const label = nrCad && area != null ? `${nrCad}\n${area} mp` : (nrCad || (area != null ? `${area} mp` : ""))
    if (!label) return null
    const labelPos = this._computeLabelPosition(geom)
    if (!labelPos) return null
    return new ol.style.Style({
      geometry: new ol.geom.Point(labelPos),
      text: new ol.style.Text({
        text:      label,
        font:      "600 11px system-ui, sans-serif",
        fill:      new ol.style.Fill({ color: "#7c2d12" }),
        stroke:    new ol.style.Stroke({ color: "#fff", width: 3 }),
        textAlign: "center",
        overflow:  true
      })
    })
  }

  _cgxmlLabelStyle(feature, resolution) {
    if (this._layerConfig?.cgxml_labels?.visible === false) return null
    const isBld   = feature.get("entity_type") === "building"
    const maxRes  = isBld ? LABEL_MAX_RESOLUTION_CLADIRI : LABEL_MAX_RESOLUTION
    if (resolution > maxRes) return null
    const idLabel = feature.get("cadgenno") || feature.get("e2identifier") || `#${feature.get("id")}`
    const geom    = feature.getGeometry()
    if (!geom) return null
    const area    = Math.round(geom.getArea())
    const label   = `${idLabel}\n${area} mp`
    const labelPos = this._computeLabelPosition(geom)
    if (!labelPos) return null
    return new ol.style.Style({
      geometry: new ol.geom.Point(labelPos),
      text: new ol.style.Text({
        text:      label,
        font:      `600 ${isBld ? 10 : 11}px system-ui, sans-serif`,
        fill:      new ol.style.Fill({ color: isBld ? "#7f1d1d" : "#92400e" }),
        stroke:    new ol.style.Stroke({ color: "#fff", width: 3 }),
        textAlign: "center",
        overflow:  true
      })
    })
  }

  _cgxmlStyle(feature) {
    const isBuilding = feature.get("entity_type") === "building"
    const cfg        = this._layerConfig?.cgxml || {}
    return new ol.style.Style({
      stroke: new ol.style.Stroke({
        color:    cfg.stroke_color || (isBuilding ? "#b91c1c" : "#92400e"),
        width:    cfg.stroke_width || (isBuilding ? 1.5 : 2),
        lineDash: this._dashArray(cfg.stroke_dash, null)
      }),
      fill: new ol.style.Fill({
        color: this._toRgba(cfg.fill_color || (isBuilding ? "rgba(252, 165, 165, 0.45)" : "rgba(252, 211, 77, 0.45)"), 1)
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
      if (this._digitizing) return  // în timpul digitizării nu afișăm popup-uri info

      let html = null, selected = null
      this.map.forEachFeatureAtPixel(evt.pixel, (feature, layer) => {
        const layerName = layer?.get("name")
        if (layerName === "parcele")  { html = this._parcelPopupHtml(feature);  selected = { kind: "parcela", feature, layer } }
        if (layerName === "cladiri")  { html = this._cladirePopupHtml(feature); selected = { kind: "cladire", feature, layer } }
        if (layerName === "cgxml")    { html = this._cgxmlPopupHtml(feature) }
        if (layerName === "uat")      { html = this._uatPopupHtml(feature) }
        return html ? true : undefined
      }, { hitTolerance: 3 })

      if (html) {
        el.innerHTML = html
        this._popup.setPosition(evt.coordinate)
      } else {
        this._popup.setPosition(undefined)
      }

      // Highlight selecție și notificăm controllerele care ascultă (digitizare)
      this._setSelectedFeature(selected)

      // Zoom pe poligonul selectat (parcelă sau clădire)
      if (selected?.feature?.getGeometry) {
        this._zoomToFeature(selected.feature)
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
    // Default: server întoarce DOAR UAT-urile care conțin parcele/clădiri.
    try {
      const res  = await fetch(this.uatUrlValue)
      const data = await res.json()
      this.uatLayer.getSource().clear()
      this._addGeoJSON(this.uatLayer, data)
    } catch (e) {
      console.warn("Nu s-a putut încărca limita UAT:", e)
    }
  }

  // ── Utilitare ─────────────────────────────────────────────────────────────

  _addGeoJSON(layer, data) {
    // GeoJSON din server vine NATIV în EPSG:3844 (Stereo 70). Niciun transform
    // necesar — coordonatele sunt cele exacte din DB. Asta elimină pierderile
    // de precizie de la round-trip 3844→4326→3844 care cauzau false-overlap-uri
    // micrometrice la digitizarea poligoanelor adiacente.
    const features = new ol.format.GeoJSON().readFeatures(data, {
      dataProjection:    "EPSG:3844",
      featureProjection: "EPSG:3844"
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
