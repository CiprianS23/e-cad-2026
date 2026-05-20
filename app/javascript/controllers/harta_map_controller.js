import { Controller } from "@hotwired/stimulus"

// Stereo70 (EPSG:3844) — proiecția națională română, sursa de adevăr pentru
// coordonate stocate. Hart conține tiles în Web Mercator (EPSG:3857) pentru
// compatibilitate cu OSM/Ortofotoplan; conversia se face on-the-fly.
const STEREO70 = "+proj=sterea +lat_0=46 +lon_0=25 +k=0.99975 +x_0=500000 +y_0=500000 +ellps=krass +towgs84=33.4,-146.6,-76.3,-0.359,-0.053,0.844,-0.84 +units=m +no_defs"

// Prag rezoluție (metri/pixel) peste care etichetele se ascund.
// Convenție: scale = resolution × 96 dpi × 39.37 inch/m ≈ resolution × 3779.5
// Pragul 1:2000 → ~0.529 m/px (etichetele apar doar zoom-in dincolo de 1:2000).
const LABEL_MAX_RESOLUTION         = 0.529   // ≈ scara 1:2 000
const LABEL_MAX_RESOLUTION_CLADIRI = 0.529   // ≈ scara 1:2 000

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
    geojsonUrl:       String,
    cgxmlGeojsonUrl:  String,
    cladiriUrl:       String,
    uatUrl:           String,
    mapproxyUrl:      String,
    baseExtent:       Array     // [minx, miny, maxx, maxy] în EPSG:3844 — limită pan + tile loading
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
    this._setupZoomPersistence()
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
    const baseExtent = this._validExtent(this.baseExtentValue)
    // maxZoom 25 → permite zoom-in până la ~1:1 (resolution ~0.0003 m/px =
    // scara 1:1 cu formula resolution × 3779.5). Anterior maxZoom 18 limita
    // la ~1:50, prea mic pentru detalii cadastrale (vertecși la cm).
    const viewOpts = {
      projection: "EPSG:3844",
      center:     baseExtent ? ol.extent.getCenter(baseExtent) : [500000, 500000],
      zoom:       2,
      minZoom:    -2,
      maxZoom:    25
    }
    if (baseExtent) {
      // Constrânge pan-ul la zona UAT + buffer (vezi HartaController#index).
      // Tile-urile basemap au și ele `extent` aplicat (vezi _buildLayers).
      viewOpts.extent = baseExtent
    }
    this.map = new ol.Map({
      target: this.element,
      controls: ol.control.defaults.defaults({ attribution: true, zoom: true }),
      view: new ol.View(viewOpts)
    })
  }

  // Stimulus Array values vin ca [] dacă atributul lipsește — întoarcem null
  // pentru a evita aplicarea unei limite nedorite.
  _validExtent(arr) {
    if (!Array.isArray(arr) || arr.length !== 4) return null
    if (!arr.every(n => typeof n === "number" && isFinite(n))) return null
    return arr
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

    // Limită spațială pentru toate layer-ele basemap (raster): OL nu cere
    // tile-uri în afara acestui extent → trafic mult redus față de a randa
    // toată România. Vezi HartaController#index.
    const baseExtent = this._validExtent(this.baseExtentValue)
    const tileLayerOpts = baseExtent ? { extent: baseExtent } : {}

    this._baseLayers = {}

    // Fallback OSM 3857 (reproject OL) — folosit dacă MapProxy nu răspunde
    const osmFallback = () => new ol.layer.Tile({
      source: new ol.source.OSM(),
      properties: { name: "OpenStreetMap (3857 reproject)" },
      ...tileLayerOpts
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
        properties: { name: "OpenStreetMap (Stereo70)" },
        ...tileLayerOpts
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
        properties: { name: "Ortofotoplan (Stereo70)" },
        ...tileLayerOpts
      })
    } else {
      this._baseLayers.osm = osmFallback()
    }

    // Layere de bază alternative — încărcate direct din surse publice (3857)
    // cu reproject pe Stereo70 făcut de OL on-the-fly.
    this._baseLayers.google_sat = new ol.layer.Tile({
      source: new ol.source.XYZ({
        urls: [
          "https://mt0.google.com/vt/lyrs=s&x={x}&y={y}&z={z}",
          "https://mt1.google.com/vt/lyrs=s&x={x}&y={y}&z={z}",
          "https://mt2.google.com/vt/lyrs=s&x={x}&y={y}&z={z}",
          "https://mt3.google.com/vt/lyrs=s&x={x}&y={y}&z={z}"
        ],
        attributions: "© Google", crossOrigin: null, maxZoom: 20
      }),
      properties: { name: "Google Satellite" },
      ...tileLayerOpts
    })

    this._baseLayers.google_hybrid = new ol.layer.Tile({
      source: new ol.source.XYZ({
        urls: [
          "https://mt0.google.com/vt/lyrs=y&x={x}&y={y}&z={z}",
          "https://mt1.google.com/vt/lyrs=y&x={x}&y={y}&z={z}",
          "https://mt2.google.com/vt/lyrs=y&x={x}&y={y}&z={z}",
          "https://mt3.google.com/vt/lyrs=y&x={x}&y={y}&z={z}"
        ],
        attributions: "© Google", crossOrigin: null, maxZoom: 20
      }),
      properties: { name: "Google Hybrid" },
      ...tileLayerOpts
    })

    this._baseLayers.esri = new ol.layer.Tile({
      source: new ol.source.XYZ({
        url:          "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
        attributions: "Tiles © Esri", crossOrigin: null, maxZoom: 19
      }),
      properties: { name: "Esri World Imagery" },
      ...tileLayerOpts
    })

    // Ortofotoplan Sascut 2022 (WMTS via proxy Rails — credențialele rămân
    // server-side). TileMatrix nativ EPSG:3844, 17 niveluri (00–16).
    // ATENȚIE axis order: WMTS publică TopLeftCorner ca "531250 646600" în
    // ordine EPSG:3844 oficială (N, E). OL lucrează (E, N) → origin = [E, N]
    // = [646600, 531250]. Resolution = ScaleDenominator × 0.00028 (96 dpi).
    this._baseLayers.ortofotoplan_sascut = new ol.layer.Tile({
      source: new ol.source.WMTS({
        url:         "/gis/wmts/sascut/{TileMatrix}/{TileCol}/{TileRow}",
        layer:       "sascut_2022",
        matrixSet:   "96dpi_3844_grid",
        format:      "image/png",
        projection:  "EPSG:3844",
        requestEncoding: "REST",
        style:       "default",
        wrapX:       false,
        tileGrid: new ol.tilegrid.WMTS({
          origin:      [646600, 531250],
          resolutions: [
            5291.6666666666, 2645.8333333333, 1322.9166666666, 529.1666666666,
            264.5833333333, 132.2916666666, 52.9166666666, 26.4583333333,
            13.2291666666, 6.6145833333, 2.6458333333, 1.3229166666,
            0.5291666666, 0.2645833333, 0.1322916666, 0.0529166666, 0.0264583333
          ],
          matrixIds: ["00","01","02","03","04","05","06","07","08","09",
                      "10","11","12","13","14","15","16"],
          tileSize:  512
        }),
        attributions: "© geosys.ro – Ortofotoplan UAT Sascut 2022"
      }),
      properties: { name: "Ortofotoplan Sascut 2022 (WMTS)" },
      ...tileLayerOpts
    })

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
      uat:            this.uatLayer,
      parcele:        this.parcelLayer,
      cladiri:        this.cladiriLayer,
      cgxml:          this.cgxmlLayer
    }

    this.map.addLayer(this.uatLayer)
    this.map.addLayer(this.parcelLayer)
    this.map.addLayer(this.cladiriLayer)
    this.map.addLayer(this.cgxmlLayer)
    this.map.addLayer(this.parcelLabelsLayer)
    this.map.addLayer(this.cladiriLabelsLayer)
    this.map.addLayer(this.cgxmlLabelsLayer)

    // Planuri vechi georeferențiate — încărcate la cerere ca image overlays.
    // Fiecare plan e ținut în `this._georefLayers[planId]` pentru a putea fi
    // controlat individual (vizibilitate, opacitate) via Layer Manager.
    this._georefLayers = {}
    this._loadGeorefPlans()
  }

  // Încarcă planurile vechi georeferențiate ale utilizatorului și le adaugă
  // ca layere `ol.layer.Image` cu sursă `ImageStatic` pe bounding box-ul
  // calculat după aplicarea transformării afine.
  async _loadGeorefPlans() {
    try {
      const r = await fetch("/gis/georef_plans", {
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
      if (!r.ok) return
      const plans = await r.json()
      const georeferenced = plans.filter(p => p.state === "georeferenced" || p.state === "finalized")
      for (const p of georeferenced) {
        await this._addGeorefLayer(p.id)
      }
      // Notifică layer-manager ca să re-aplice config-ul pe layer-ele noi.
      // (Layer-manager poate fi conectat înainte ca planurile să fie create
      //  async, deci applyLayerConfig anterior pentru `georef_plan_<id>`
      //  a fost no-op).
      this.element.dispatchEvent(new CustomEvent("harta-map:georef-loaded", {
        bubbles: true,
        detail: { planIds: georeferenced.map(p => p.id) }
      }))
    } catch (e) {
      console.warn("Nu pot încărca planurile georeferențiate:", e)
    }
  }

  async _addGeorefLayer(planId) {
    try {
      const r = await fetch(`/gis/georef_plans/${planId}`, {
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
      const d = await r.json()
      const url    = d.display_url || d.warped_url || d.raster_url
      const bounds = d.bounds_extent
      if (!url || !bounds) return

      // Salvăm config-ul nativ pe layer pentru a-l recrea la toggle bg_transparent
      const layer = new ol.layer.Image({
        opacity:    1.0,
        source:     this._makeGeorefSource(url, bounds, /* bgTransparent */ true),
        zIndex:     90,
        properties: {
          name:        `georef_plan_${planId}`,
          plan_name:   d.name,
          plan_state:  d.state,
          source_url:  url,
          bounds_3844: bounds
        }
      })
      this.map.addLayer(layer)
      this._georefLayers[planId] = layer
    } catch (e) {
      console.warn(`Nu pot adăuga planul #${planId}:`, e)
    }
  }

  // Construiește o sursă ImageStatic pentru un plan raster. Dacă `bgTransparent`
  // = true, aplică filtru pixel pe canvas pentru a face pixelii albi (sub
  // pragul de threshold) transparenți → vezi doar liniile/textul desenat.
  _makeGeorefSource(url, bounds, bgTransparent) {
    const opts = {
      url,
      imageExtent: bounds,
      projection:  "EPSG:3844",
      crossOrigin: "anonymous"
    }
    if (bgTransparent) {
      opts.imageLoadFunction = (image, src) => this._loadKeyed(image, src)
    }
    return new ol.source.ImageStatic(opts)
  }

  // Procesează imaginea client-side pe canvas: pixelii albi (R,G,B toți ≥ 230)
  // devin transparenți. Pragul 230 acoperă scanări cu hârtie ușor îngălbenită
  // sau anti-aliasing pe margini. Pentru praguri diferite se poate adăuga
  // ulterior un slider în layer manager.
  _loadKeyed(image, src) {
    const img = new Image()
    img.crossOrigin = "anonymous"
    img.onload = () => {
      const canvas = document.createElement("canvas")
      canvas.width  = img.naturalWidth
      canvas.height = img.naturalHeight
      const ctx = canvas.getContext("2d", { willReadFrequently: false })
      ctx.drawImage(img, 0, 0)
      try {
        const imgData = ctx.getImageData(0, 0, canvas.width, canvas.height)
        const data = imgData.data
        const T = 230  // threshold: 230..255 = considerat fundal alb
        for (let i = 0; i < data.length; i += 4) {
          if (data[i] >= T && data[i + 1] >= T && data[i + 2] >= T) {
            data[i + 3] = 0
          }
        }
        ctx.putImageData(imgData, 0, 0)
      } catch (e) {
        console.warn("Filter white-removal eșuat (CORS?):", e)
      }
      canvas.toBlob((blob) => {
        if (!blob) { image.getImage().src = src; return }
        const blobUrl = URL.createObjectURL(blob)
        image.getImage().src = blobUrl
      }, "image/png")
    }
    img.onerror = () => { image.getImage().src = src }
    img.src = src
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
    // Toggle pe „cladiri" afectează și cgxml buildings — vezi _cgxmlStyle.
    // (Toggle pe „parcele" controlează DOAR drafturi; cgxml lands au toggle-ul
    // lor separat „cgxml" = Imobile cgxml.)
    if (name === "cladiri") {
      if (!this._layerConfig) this._layerConfig = {}
      this._layerConfig.cladiri = { ...(this._layerConfig.cladiri || {}), visible }
      this.cgxmlLayer?.changed()
      this.cgxmlLabelsLayer?.changed()
    }
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

    // Toggle pe „cladiri" afectează AMBELE surse — drafturi + cgxml buildings
    // (filtrul e în _cgxmlStyle / _cgxmlLabelStyle pe entity_type='building').
    // Forțăm redraw pe cgxml ca să re-evalueze stilurile.
    if (layerKey === "cladiri" && typeof merged.visible === "boolean") {
      this.cgxmlLayer?.changed()
      this.cgxmlLabelsLayer?.changed()
    }
    if (layerKey === "parcele" || layerKey === "cladiri") {
      // Label-ul drafturilor urmărește vizibilitatea layer-ului principal,
      // ca în vechiul toggleOverlay (legacy path).
      const labelsLayer = layerKey === "parcele" ? this.parcelLabelsLayer : this.cladiriLabelsLayer
      if (typeof merged.visible === "boolean") labelsLayer?.setVisible(merged.visible)
    }

    // Pentru layere raster (georef_plan_*): toggle bg_transparent → recreăm
    // sursa cu/fără filtru de eliminare fundal alb.
    if (typeof merged.bg_transparent === "boolean" && layerKey.startsWith("georef_plan_")) {
      const props = layer.getProperties()
      const currentBg = !!props._bg_transparent
      if (currentBg !== merged.bg_transparent) {
        layer.setSource(this._makeGeorefSource(
          props.source_url, props.bounds_3844, merged.bg_transparent
        ))
        layer.set("_bg_transparent", merged.bg_transparent)
      }
    }

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
    if (map[key]) return map[key]
    // Planurile raster georef sunt cheiate ca `georef_plan_<id>`
    const m = key && key.match(/^georef_plan_(\d+)$/)
    if (m) return this._georefLayers?.[parseInt(m[1], 10)] || null
    return null
  }

  setDigitizing(active) {
    this._digitizing = active
    if (active) this._popup?.setPosition(undefined)
  }

  // ── Selecție feature (pentru Edit mode) ────────────────────────────────

  _setSelectedFeature(sel, { silent = false } = {}) {
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
    if (!silent) {
      this.dispatch(sel ? "feature-selected" : "feature-deselected", {
        detail: sel,
        bubbles: true
      })
    }
  }

  clearSelection() { this._setSelectedFeature(null) }

  // ── Selecție multiplă (pentru ștergere în bloc) ─────────────────────────

  enableMultiSelect() {
    if (this._multiSelectMode) return
    this._multiSelectMode = true
    this.clearSelection()  // închide popup-ul/selecția single ca să nu existe stări mixte
    this._ensureMultiSelectLayer()
    this._ensureDragBox()
    if (this._dragBox) this._dragBox.setActive(true)
    this.dispatch("multi-select-mode", { detail: { active: true }, bubbles: true })
  }

  disableMultiSelect() {
    if (!this._multiSelectMode) return
    this._multiSelectMode = false
    if (this._dragBox) this._dragBox.setActive(false)
    if (this._polySelectDraw) this._endPolygonSelect()
    this.clearMultiSelection()
    this.dispatch("multi-select-mode", { detail: { active: false }, bubbles: true })
  }

  clearMultiSelection() {
    if (!this._multiSelected) this._multiSelected = new Map()
    this._multiSelected.clear()
    this._refreshMultiSelectOverlay()
    this._dispatchMultiChanged()
  }

  getMultiSelection() {
    return Array.from(this._multiSelected?.values() || [])
  }

  _multiKey(kind, id) { return `${kind}-${id}` }

  _ensureMultiSelectLayer() {
    if (this._multiSelectLayer) return
    this._multiSelected = new Map()
    this._multiSelectLayer = new ol.layer.Vector({
      source: new ol.source.Vector(),
      style:  () => new ol.style.Style({
        stroke: new ol.style.Stroke({ color: "#f97316", width: 3 }),
        fill:   new ol.style.Fill({ color: "rgba(249, 115, 22, 0.20)" })
      }),
      zIndex: 998
    })
    this.map.addLayer(this._multiSelectLayer)
  }

  _ensureDragBox() {
    if (this._dragBox) return
    // Shift+drag pentru box-select — convenție GIS standard, nu interferează cu pan.
    this._dragBox = new ol.interaction.DragBox({
      condition: ol.events.condition.shiftKeyOnly
    })
    this._dragBox.on("boxend", () => {
      const extent = this._dragBox.getGeometry().getExtent()
      this._selectFeaturesInExtent(extent)
    })
    this._dragBox.setActive(false)
    this.map.addInteraction(this._dragBox)
  }

  _selectFeaturesInExtent(extent) {
    const layers = [
      { layer: this.parcelLayer,  kind: "parcela" },
      { layer: this.cladiriLayer, kind: "cladire" },
      // CGXML — kind derivat din entity_type (land→parcela, building→cladire).
      // Conține drumuri, ape, păduri etc. — toate ca lands extinși.
      { layer: this.cgxmlLayer,   kind: null }
    ]
    let added = 0
    layers.forEach(({ layer, kind }) => {
      if (!layer || layer.getVisible?.() === false) return
      const src = layer.getSource?.()
      if (!src) return
      src.forEachFeatureIntersectingExtent(extent, (feature) => {
        const id = feature.get("id")
        if (id == null) return
        let k = kind
        if (k === null) {
          const et = feature.get("entity_type")
          k = et === "building" ? "cladire" : "parcela"
        }
        const key = this._multiKey(k, id)
        if (!this._multiSelected.has(key)) {
          this._multiSelected.set(key, { kind: k, feature, layer })
          added++
        }
      })
    })
    if (added > 0) {
      this._refreshMultiSelectOverlay()
      this._dispatchMultiChanged()
    }
  }

  // Inițiază desenarea unui poligon neregulat de selecție.
  // Click adaugă vertex, dublu-click închide, Esc anulează.
  // Auto-activează modul multi-select dacă nu e deja activ.
  startPolygonSelect() {
    if (this._polySelectDraw) return  // deja în curs
    if (!this._multiSelectMode) this.enableMultiSelect()

    const source = new ol.source.Vector()
    if (!this._polySelectLayer) {
      this._polySelectLayer = new ol.layer.Vector({
        source,
        style: new ol.style.Style({
          stroke: new ol.style.Stroke({ color: "#ea580c", width: 2, lineDash: [6, 4] }),
          fill:   new ol.style.Fill({ color: "rgba(249, 115, 22, 0.08)" }),
          image:  new ol.style.Circle({
            radius: 4,
            fill:   new ol.style.Fill({ color: "#ea580c" }),
            stroke: new ol.style.Stroke({ color: "#fff", width: 1.5 })
          })
        }),
        zIndex: 997
      })
      this.map.addLayer(this._polySelectLayer)
    } else {
      this._polySelectLayer.setSource(source)
    }

    this._polySelectDraw = new ol.interaction.Draw({
      source,
      type: "Polygon"
    })
    this._polySelectDraw.on("drawend", (evt) => {
      const poly = evt.feature.getGeometry()
      this._selectFeaturesByPolygon(poly)
      // curățăm imediat — geometria de selecție nu rămâne pe hartă
      setTimeout(() => this._endPolygonSelect(), 50)
    })
    this.map.addInteraction(this._polySelectDraw)

    if (!this._polySelectKeyHandler) {
      this._polySelectKeyHandler = (e) => {
        if (e.key === "Escape" && this._polySelectDraw) this._endPolygonSelect()
      }
      document.addEventListener("keydown", this._polySelectKeyHandler)
    }

    this.dispatch("polygon-select-mode", { detail: { active: true }, bubbles: true })
  }

  _endPolygonSelect() {
    if (this._polySelectDraw) {
      this.map.removeInteraction(this._polySelectDraw)
      this._polySelectDraw = null
    }
    if (this._polySelectLayer) {
      this._polySelectLayer.getSource().clear()
    }
    if (this._polySelectKeyHandler) {
      document.removeEventListener("keydown", this._polySelectKeyHandler)
      this._polySelectKeyHandler = null
    }
    this.dispatch("polygon-select-mode", { detail: { active: false }, bubbles: true })
  }

  // Selectează parcele/clădiri care intersectează poligonul de selecție.
  // Folosește JSTS pentru intersecție reală (nu doar bounding box).
  _selectFeaturesByPolygon(olPolygon) {
    const parser = this._getJstsParser()
    if (!parser) {  // JSTS lipsă — fallback la bbox
      return this._selectFeaturesInExtent(olPolygon.getExtent())
    }
    const jstsSelector = parser.read(olPolygon)
    const extent = olPolygon.getExtent()
    const layers = [
      { layer: this.parcelLayer,  kind: "parcela" },
      { layer: this.cladiriLayer, kind: "cladire" },
      // CGXML — kind derivat din entity_type ca să prindem și poligoanele
      // lungi (drumuri, ape, păduri) care doar intersectează lasso-ul.
      { layer: this.cgxmlLayer,   kind: null }
    ]
    let added = 0
    layers.forEach(({ layer, kind }) => {
      if (!layer || layer.getVisible?.() === false) return
      const src = layer.getSource?.()
      if (!src) return
      src.forEachFeatureIntersectingExtent(extent, (feature) => {
        const id = feature.get("id")
        if (id == null) return
        let k = kind
        if (k === null) {
          const et = feature.get("entity_type")
          k = et === "building" ? "cladire" : "parcela"
        }
        const key = this._multiKey(k, id)
        if (this._multiSelected.has(key)) return
        try {
          const jstsGeom = parser.read(feature.getGeometry())
          if (jstsSelector.intersects(jstsGeom)) {
            this._multiSelected.set(key, { kind: k, feature, layer })
            added++
          }
        } catch (_e) { /* geometrie invalidă — ignor */ }
      })
    })
    if (added > 0) {
      this._refreshMultiSelectOverlay()
      this._dispatchMultiChanged()
    }
  }

  _getJstsParser() {
    if (this._jstsParser !== undefined) return this._jstsParser
    if (typeof jsts === "undefined" || !jsts.io?.OL3Parser) {
      this._jstsParser = null
      return null
    }
    const parser = new jsts.io.OL3Parser()
    parser.inject(
      ol.geom.Point, ol.geom.LineString, ol.geom.LinearRing,
      ol.geom.Polygon, ol.geom.MultiPoint,
      ol.geom.MultiLineString, ol.geom.MultiPolygon
    )
    this._jstsParser = parser
    return parser
  }

  _toggleFeatureInMulti(sel) {
    if (!sel) return
    this._ensureMultiSelectLayer()
    const id = sel.feature.get("id")
    if (id == null) return
    const key = this._multiKey(sel.kind, id)
    if (this._multiSelected.has(key)) {
      this._multiSelected.delete(key)
    } else {
      this._multiSelected.set(key, sel)
    }
    this._refreshMultiSelectOverlay()
    this._dispatchMultiChanged()
  }

  _refreshMultiSelectOverlay() {
    if (!this._multiSelectLayer) return
    const src = this._multiSelectLayer.getSource()
    src.clear()
    this._multiSelected.forEach(({ feature }) => {
      src.addFeature(new ol.Feature({ geometry: feature.getGeometry().clone() }))
    })
  }

  _dispatchMultiChanged() {
    this.dispatch("multi-selection-changed", {
      detail: {
        count: this._multiSelected?.size || 0,
        items: this.getMultiSelection()
      },
      bubbles: true
    })
  }

  // Zoom maxim cu poligonul integral în viewport — `view.fit` calculează cel
  // mai înalt nivel de zoom la care extent-ul încape, cu padding mic pentru
  // un mic spațiu vizual în jurul geometriei (~40 px pe fiecare latură).
  _zoomToFeature(feature) {
    const geom = feature.getGeometry?.()
    if (!geom) return
    this.map.getView().fit(geom, {
      padding:  [40, 40, 40, 40],
      duration: 400
    })
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
  // Calculează poziția etichetei pentru un poligon: centrul porțiunii vizibile
  // în viewport. Algoritm:
  //   1. Dacă poligonul nu intersectează viewport-ul → null (label invizibil)
  //   2. Dacă poligonul e integral în viewport → interior point clasic
  //   3. Altfel (parțial vizibil) → intersecția REALĂ poligon ∩ viewport via
  //      JSTS și interior point al intersecției → label apare în centrul
  //      vizual al porțiunii din poligon care e efectiv vizibilă pe ecran.
  //   4. Fallback fără JSTS: bbox-intersection center + clamp pe boundary.
  _computeLabelPosition(geom) {
    if (!this.map) return this._geomInteriorPoint(geom)
    const viewExt = this.map.getView().calculateExtent(this.map.getSize())
    const polyExt = geom.getExtent()
    if (!ol.extent.intersects(polyExt, viewExt)) return null

    // Poligonul e integral în viewport → centrul real al poligonului.
    if (ol.extent.containsExtent(viewExt, polyExt)) {
      return this._geomInteriorPoint(geom)
    }

    // Poligonul depășește viewport-ul → label-ul merge în centrul porțiunii vizibile.
    const parser = this._getJstsParser?.()
    if (parser) {
      try {
        const jstsGeom = parser.read(geom)
        const [minx, miny, maxx, maxy] = viewExt
        const factory = new jsts.geom.GeometryFactory()
        const coords  = [
          new jsts.geom.Coordinate(minx, miny),
          new jsts.geom.Coordinate(maxx, miny),
          new jsts.geom.Coordinate(maxx, maxy),
          new jsts.geom.Coordinate(minx, maxy),
          new jsts.geom.Coordinate(minx, miny)
        ]
        const ring     = factory.createLinearRing(coords)
        const viewJsts = factory.createPolygon(ring, [])
        const inter    = jstsGeom.intersection(viewJsts)
        if (inter && !inter.isEmpty()) {
          const interOl = parser.write(inter)
          const t = interOl.getType()
          // intersection poate fi Polygon sau MultiPolygon (poligon cu mai multe
          // bucăți vizibile). Folosim interior point al rezultatului.
          if (t === "Polygon" || t === "MultiPolygon") {
            return this._geomInteriorPoint(interOl)
          }
        }
      } catch (_) { /* fallback la bbox-intersection */ }
    }

    // Fallback: centrul bbox-ului de intersecție, clamp pe poligon.
    const interExt = ol.extent.getIntersection(polyExt, viewExt)
    if (ol.extent.isEmpty(interExt)) return null
    const c = ol.extent.getCenter(interExt)
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
    // Vezi _cgxmlStyle: doar buildings sunt cuplate cu toggle-ul „cladiri";
    // cgxml lands urmează doar toggle-ul „cgxml" (Imobile cgxml).
    if (isBld && this._layerConfig?.cladiri?.visible === false) return null
    const maxRes  = isBld ? LABEL_MAX_RESOLUTION_CLADIRI : LABEL_MAX_RESOLUTION
    if (resolution > maxRes) return null
    const idLabel = feature.get("cadgenno") || feature.get("e2identifier") || `#${feature.get("id")}`
    const geom    = feature.getGeometry()
    if (!geom) return null
    // getArea() există doar pe Polygon/MultiPolygon — pentru tipuri neașteptate skip.
    if (typeof geom.getArea !== "function") return null
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
    // Modelul de toggle e ASIMETRIC:
    //   • „cgxml" (Imobile cgxml) controlează cgxml lands. Toggle parcele
    //     NU afectează cgxml lands — sunt entități separate (în layer manager
    //     parcele = drafturi locale).
    //   • „cladiri" controlează AMBELE — drafturile + cgxml buildings. O clădire
    //     e o clădire, indiferent de sursă; toggle-ul ascunde toate.
    if (isBuilding && this._layerConfig?.cladiri?.visible === false) return null
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
      if (this._digitizing) return  // în timpul digitizării nu intervenim cu selecția info

      let selected = null
      this.map.forEachFeatureAtPixel(evt.pixel, (feature, layer) => {
        const layerName = layer?.get("name")
        if (layerName === "parcele") { selected = { kind: "parcela", feature, layer }; return true }
        if (layerName === "cladiri") { selected = { kind: "cladire", feature, layer }; return true }
        if (layerName === "cgxml") {
          // CGXML mixează terenuri (entity_type=land) și construcții (=building).
          const et = feature.get("entity_type")
          if (et === "land")     selected = { kind: "parcela", feature, layer }
          if (et === "building") selected = { kind: "cladire", feature, layer }
          if (selected) return true
        }
        return undefined
      }, { hitTolerance: 3 })

      // În modul multi-select: click toggle pe feature în set, fără popup/zoom.
      if (this._multiSelectMode) {
        if (selected) this._toggleFeatureInMulti(selected)
        return
      }

      // Highlight selecție + notifică controllerele (digitizare → buton Modifică)
      this._setSelectedFeature(selected)
      this._cancelHoverPopup()  // ascunde popup-ul dacă era în curs/afișat

      // Persist focused entity în URL (zoom_land / zoom_building) — la refresh,
      // `_zoomFromUrlParams` centrează pe entitate. Pentru click pe gol, ștergem.
      this._updateFocusUrlParams(selected)

      // Zoom pe poligonul selectat (parcelă sau clădire)
      if (selected?.feature?.getGeometry) {
        this._zoomToFeature(selected.feature)
      }
    })

    // Popup info la mouse-over cu delay de 1s/geometrie. Se afișează doar dacă
    // utilizatorul stă pe același feature minim 1 secundă. Suprimă popup-ul:
    //  - în modul digitizare / multi-select (interferează cu interacțiunea)
    //  - când hover-ezi pe FEATURE-UL DEJA selectat (info-ul e în sidebar);
    //    pe ALTE features popup-ul rămâne disponibil chiar dacă ai selecție.
    this.map.on("pointermove", (evt) => {
      if (evt.dragging) return

      if (this._digitizing || this._multiSelectMode) {
        this._popup?.setPosition(undefined)
        this.map.getTargetElement().style.cursor = ""
        this._cancelHoverPopup()
        return
      }

      let hoveredFeature = null
      let hoveredLayer   = null
      let hoveredKey     = null
      this.map.forEachFeatureAtPixel(evt.pixel, (feature, layer) => {
        const layerName = layer?.get("name")
        if (!["parcele","cladiri","cgxml","uat"].includes(layerName)) return undefined
        hoveredFeature = feature
        hoveredLayer   = layer
        const id = feature.get("id") ?? feature.get("nat_code") ?? ""
        const et = feature.get("entity_type") || ""
        hoveredKey = `${layerName}-${et}-${id}`
        return true
      }, { hitTolerance: 3 })

      this.map.getTargetElement().style.cursor = hoveredFeature ? "pointer" : ""

      if (!hoveredFeature) {
        this._popup.setPosition(undefined)
        this._cancelHoverPopup()
        return
      }

      // Suprimă popup-ul DOAR dacă hoverezi feature-ul deja selectat.
      if (this._selected?.feature === hoveredFeature) {
        this._popup.setPosition(undefined)
        this._cancelHoverPopup()
        this._lastHoverKey = hoveredKey
        return
      }

      // Același feature: dacă popup-ul e deja vizibil, urmărim cursorul; altfel
      // lăsăm timer-ul în curs să-l afișeze după cele 1s.
      if (hoveredKey === this._lastHoverKey) {
        if (this._popupShown) this._popup.setPosition(evt.coordinate)
        return
      }

      // Feature nou → resetăm + pornim timer 1s
      this._cancelHoverPopup()
      this._lastHoverKey = hoveredKey

      const coord     = evt.coordinate
      const feature   = hoveredFeature
      const layerName = hoveredLayer.get("name")
      this._hoverTimer = setTimeout(() => {
        let html = null
        if (layerName === "parcele") html = this._parcelPopupHtml(feature)
        if (layerName === "cladiri") html = this._cladirePopupHtml(feature)
        if (layerName === "cgxml")   html = this._cgxmlPopupHtml(feature)
        if (layerName === "uat")     html = this._uatPopupHtml(feature)
        if (!html) return
        el.innerHTML = html
        this._popup.setPosition(coord)
        this._popupShown = true
      }, 1000)
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
        <a href="/lands/${f.get("id")}" class="btn btn-sm btn-primary" style="margin-top:6px">Detalii</a>
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
        <a href="/buildings/${f.get("id")}" class="btn btn-sm btn-primary" style="margin-top:6px">Detalii</a>
      </div>
    `
  }

  _cgxmlPopupHtml(f) {
    const isBuilding = f.get("entity_type") === "building"
    const title      = isBuilding ? `Construcție #${f.get("buildno") ?? f.get("id")}` : "Imobil"
    const ie         = f.get("cadgenno") || f.get("e2identifier") || "—"
    const mp = (v) => v != null ? `${Number(v).toLocaleString("ro-RO", { maximumFractionDigits: 2 })} mp` : "—"
    // Detaliile (proprietari + acte) se cer async, pe baza id-ului — vezi `_loadPopupDetails`.
    const popupId = `popup-${isBuilding ? "b" : "l"}-${f.get("id")}`
    setTimeout(() => this._loadPopupDetails(f.get("id"), isBuilding, popupId), 0)
    return `
      <div class="map-popup cgxml-popup" id="${popupId}">
        <div class="popup-title">${title}</div>
        <table class="popup-table">
          <tr><th>Nr. IE</th><td>${ie}</td></tr>
          <tr><th>Suprafață</th><td>${mp(f.get("measuredarea"))}</td></tr>
          <tr><th>Proprietari</th><td data-role="owners"><em>se încarcă…</em></td></tr>
          <tr><th>Acte</th><td data-role="deeds"><em>se încarcă…</em></td></tr>
        </table>
      </div>
    `
  }

  // Cere /lands/:id/popup_info.json (sau /buildings/...) și populează popup-ul.
  // Sigur la închidere rapidă a popup-ului: dacă nodul nu mai există, ignoră.
  async _loadPopupDetails(id, isBuilding, popupId) {
    const url = isBuilding ? `/buildings/${id}/popup_info.json` : `/lands/${id}/popup_info.json`
    try {
      const res  = await fetch(url, { headers: { Accept: "application/json" } })
      if (!res.ok) return
      const data = await res.json()
      const root = document.getElementById(popupId)
      if (!root) return  // popup-ul s-a închis între timp
      const ownersEl = root.querySelector('[data-role="owners"]')
      const deedsEl  = root.querySelector('[data-role="deeds"]')
      if (ownersEl) {
        const owners = (data.owners || [])
          .filter(o => o && (o.lastname || o.firstname))
          .map(o => [o.lastname, o.fatherinitial, o.firstname].filter(Boolean).join(" "))
        ownersEl.innerHTML = owners.length ? owners.map(o => `<div>${o}</div>`).join("") : "—"
      }
      if (deedsEl) {
        const fmtDate = (d) => {
          if (!d) return ""
          try { return new Date(d).toLocaleDateString("ro-RO") } catch (_) { return d }
        }
        const deeds = (data.deeds || [])
          .filter(d => d && (d.deednumber || d.deedtype))
          .map(d => {
            const parts = []
            if (d.deedtype)   parts.push(d.deedtype)
            if (d.deednumber) parts.push(`nr. ${d.deednumber}`)
            if (d.deeddate)   parts.push(fmtDate(d.deeddate))
            if (d.authority)  parts.push(`(${d.authority})`)
            return parts.join(" ")
          })
        deedsEl.innerHTML = deeds.length ? deeds.map(d => `<div>${d}</div>`).join("") : "—"
      }
    } catch (e) {
      // network error — lăsăm "se încarcă..." să devină — pe retry / alt click
    }
  }

  _uatPopupHtml(f) {
    return `<div class="map-popup"><strong>${f.get("name") || f.get("nat_code") || "UAT"}</strong></div>`
  }

  // ── Încărcare date GeoJSON ───────────────────────────────────────────────

  async _loadParcele() {
    try {
      const res  = await fetch(this.geojsonUrlValue)
      const data = await res.json()
      this.parcelLayer.getSource().clear()
      this._addGeoJSON(this.parcelLayer, data)
      if (!this._parceleLoaded) {
        this._fitToLayer(this.parcelLayer)
        this._loadUatForCenter(this.parcelLayer)
        this._parceleLoaded = true
      }
    } catch (e) {
      console.warn("Nu s-au putut încărca parcelele:", e)
    }
    this._zoomFromUrlParams()
  }

  async _loadCgxml() {
    if (!this.cgxmlGeojsonUrlValue) return
    try {
      const res  = await fetch(this.cgxmlGeojsonUrlValue)
      const data = await res.json()
      this.cgxmlLayer.getSource().clear()
      this._addGeoJSON(this.cgxmlLayer, data)
      if (!this._cgxmlLoaded && this.parcelLayer.getSource().getFeatures().length === 0) {
        this._fitToLayer(this.cgxmlLayer)
        this._loadUatForCenter(this.cgxmlLayer)
      }
      this._cgxmlLoaded = true
    } catch (e) {
      console.warn("Nu s-au putut încărca imobilele CGXML:", e)
    }
    this._zoomFromUrlParams()
  }

  async _loadCladiri() {
    if (!this.cladiriUrlValue) return
    try {
      const res  = await fetch(this.cladiriUrlValue)
      const data = await res.json()
      this.cladiriLayer.getSource().clear()
      this._addGeoJSON(this.cladiriLayer, data)
    } catch (e) {
      console.warn("Nu s-au putut încărca clădirile:", e)
    }
    this._zoomFromUrlParams()
  }

  // Persist entitatea focalizată în URL ca query params (`zoom_land` /
  // `zoom_building`). `history.replaceState` schimbă URL-ul fără reload — la
  // refresh manual, `_zoomFromUrlParams` reaplică centrarea.
  // Anulează un timer de hover în curs și ascunde popup-ul dacă era afișat.
  _cancelHoverPopup() {
    if (this._hoverTimer) { clearTimeout(this._hoverTimer); this._hoverTimer = null }
    if (this._popupShown) { this._popup?.setPosition(undefined); this._popupShown = false }
    this._lastHoverKey = null
  }

  // Persistă entitatea focalizată în CACHE-ul UTILIZATORULUI (localStorage),
  // nu în URL. URL-ul rămâne curat; restaurarea funcționează doar local pe
  // browser-ul utilizatorului. (URL params `zoom_land/zoom_building` mai sunt
  // citite la load pentru link-uri externe „Vezi pe hartă" din /lands/:id.)
  _updateFocusUrlParams(sel) {
    try {
      if (!sel) {
        localStorage.removeItem("harta:lastEntity")
        return
      }
      const id = sel.feature.get("id")
      if (!id) return
      const kind = sel.kind === "cladire" ? "cladire" : "parcela"
      const view = this.map?.getView?.()
      localStorage.setItem("harta:lastEntity", JSON.stringify({
        kind, id: String(id),
        center: view?.getCenter?.() || null,
        zoom:   view?.getZoom?.() || null,
        ts:     Date.now()
      }))
    } catch (_) { /* no-op */ }
  }

  // Setează listener pe `moveend` care actualizează zoom-ul + center-ul
  // în localStorage CÂND există o entitate focalizată (selectată). La refresh,
  // `_zoomFromUrlParams` folosește valoarea ca să restaureze view-ul.
  _setupZoomPersistence() {
    if (this._zoomPersistInit) return
    this._zoomPersistInit = true
    this.map.on("moveend", () => {
      if (this._restoringView) return
      try {
        const view = this.map.getView()
        const center = view.getCenter()
        const zoom   = view.getZoom()
        // Salvăm întotdeauna VIEWPORT-ul curent (orice operațiune: pan, zoom,
        // edit, save) — la refresh utilizatorul revine în zona unde lucra.
        localStorage.setItem("harta:lastViewport", JSON.stringify({
          center, zoom, ts: Date.now()
        }))
        // În plus, dacă există entitate focalizată, updateăm și acel cache
        // (păstrează asocierea entitate ↔ viewport).
        const raw = localStorage.getItem("harta:lastEntity")
        if (raw) {
          const data = JSON.parse(raw)
          if (data?.id) {
            data.center = center
            data.zoom   = zoom
            data.ts     = Date.now()
            localStorage.setItem("harta:lastEntity", JSON.stringify(data))
          }
        }
      } catch (_) { /* no-op */ }
    })
  }

  // Restaurează ultima entitate focalizată din cache utilizator (localStorage)
  // sau, ca fallback, dintr-un URL param explicit (`?zoom_land=ID` / `zoom_building`)
  // — util pentru link-uri externe gen „Vezi pe hartă" din /lands/:id.
  // Apelat după fiecare layer load; flag-ul `_zoomedFromUrl` previne re-zoom.
  _zoomFromUrlParams() {
    if (this._zoomedFromUrl) return

    // 1) URL param (priorită — navigare explicită)
    const url    = new URL(window.location.href)
    const landId = url.searchParams.get("zoom_land")
    const bldId  = url.searchParams.get("zoom_building")
    let target   = null
    if (landId) target = { kind: "parcela", id: String(landId), savedZoom: parseFloat(url.searchParams.get("z")) }
    else if (bldId) target = { kind: "cladire", id: String(bldId), savedZoom: parseFloat(url.searchParams.get("z")) }

    // 2) Fallback A: ultima entitate focalizată (selectată/editată)
    if (!target) {
      try {
        const raw = localStorage.getItem("harta:lastEntity")
        if (raw) {
          const data = JSON.parse(raw)
          if (data?.id) {
            target = { kind: data.kind, id: String(data.id), savedZoom: data.zoom, savedCenter: data.center }
          }
        }
      } catch (_) { /* no-op */ }
    }
    // 3) Fallback B: ultimul viewport (orice operațiune — pan, zoom, digitizare,
    //    save) — chiar dacă nu există entitate focalizată, ne întoarcem în zona
    //    unde lucra utilizatorul.
    if (!target) {
      try {
        const raw = localStorage.getItem("harta:lastViewport")
        if (raw) {
          const data = JSON.parse(raw)
          if (Array.isArray(data?.center) && Number.isFinite(data?.zoom)) {
            this._zoomedFromUrl = true
            this._restoringView = true
            this.map.getView().setCenter(data.center)
            this.map.getView().setZoom(data.zoom)
            setTimeout(() => { this._restoringView = false }, 350)
            return
          }
        }
      } catch (_) { /* no-op */ }
    }
    if (!target) return

    const findIn = (layer, predicate) => layer?.getSource().getFeatures().find(predicate)
    const cgxmlEt = target.kind === "cladire" ? "building" : "land"
    let feat = null
    if (target.kind === "parcela") {
      feat = findIn(this.parcelLayer, f => String(f.get("id")) === target.id) ||
             findIn(this.cgxmlLayer,  f => f.get("entity_type") === cgxmlEt && String(f.get("id")) === target.id)
    } else {
      feat = findIn(this.cladiriLayer, f => String(f.get("id")) === target.id) ||
             findIn(this.cgxmlLayer,   f => f.get("entity_type") === cgxmlEt && String(f.get("id")) === target.id)
    }
    if (!feat) return
    this._zoomedFromUrl = true
    const savedZoom = target.savedZoom
    if (Number.isFinite(savedZoom)) {
      // Restaurăm nivelul de zoom salvat (după ce user-a zoom-ait manual peste
      // default-ul fit-to-feature). Centrăm pe feature pentru ca tot să fie
      // vizibil. `_restoringView` previne loop-ul moveend → URL update.
      const ext = feat.getGeometry().getExtent()
      const cx  = (ext[0] + ext[2]) / 2
      const cy  = (ext[1] + ext[3]) / 2
      this._restoringView = true
      this.map.getView().setCenter([cx, cy])
      this.map.getView().setZoom(savedZoom)
      setTimeout(() => { this._restoringView = false }, 350)
    } else {
      this._zoomToFeature(feat)
    }

    // Re-selectează feature-ul ca să apară highlightat + butoanele Modifică/
    // Șterge din sidebar să fie active după refresh.
    const layerOwning = [this.parcelLayer, this.cladiriLayer, this.cgxmlLayer]
      .find(l => l?.getSource().getFeatures().includes(feat))
    if (layerOwning) {
      this._setSelectedFeature({ kind: target.kind, feature: feat, layer: layerOwning })
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
    this.map.getView().fit(extent, { padding: [40, 40, 40, 40], maxZoom: 20, duration: 300 })
  }
}
