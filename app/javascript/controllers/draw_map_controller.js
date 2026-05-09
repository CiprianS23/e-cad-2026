import { Controller } from "@hotwired/stimulus"

// Controlează widgetul de desenare din formularul parcelei
// Convertește coordonatele WGS84 (Leaflet) → Stereo70 (SRID 3844) via proj4
export default class extends Controller {
  static targets = ["wktField", "mapContainer", "toggleBtn"]
  static values  = { existingWkt: String }

  // Definiție proj4 pentru EPSG:3844 (Stereo70 România)
  STEREO70_DEF = "+proj=sterea +lat_0=46 +lon_0=25 +k=0.9996 +x_0=500000 +y_0=500000 +ellps=krass +towgs84=33.4,-146.6,-76.3,-0.359,-0.053,0.844,-0.84 +units=m +no_defs"

  connect() {
    proj4.defs("EPSG:3844", this.STEREO70_DEF)
    this._mapInitialized = false
  }

  toggle() {
    if (this._mapInitialized) {
      const el = this.mapContainerTarget
      el.hidden = !el.hidden
      if (!el.hidden) this.map.invalidateSize()
      return
    }
    this.mapContainerTarget.hidden = false
    this._initMap()
  }

  _initMap() {
    this._mapInitialized = true

    this.map = L.map(this.mapContainerTarget, {
      center: [45.75, 24.9],
      zoom: 7
    })

    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
      attribution: "© OpenStreetMap contributors",
      maxZoom: 19
    }).addTo(this.map)

    // Leaflet.draw — toolbar cu opțiune polygon
    this.drawnItems = new L.FeatureGroup().addTo(this.map)

    const drawControl = new L.Control.Draw({
      edit: { featureGroup: this.drawnItems },
      draw: {
        polygon:   { shapeOptions: { color: "#1d4ed8" } },
        polyline:  false,
        rectangle: false,
        circle:    false,
        marker:    false,
        circlemarker: false
      }
    })
    this.map.addControl(drawControl)

    // Dacă există WKT, afișăm geometria existentă convertită la WGS84
    if (this.existingWktValue) {
      this._afiseazaGeometrieExistenta(this.existingWktValue)
    }

    this.map.on(L.Draw.Event.CREATED, (e) => {
      this.drawnItems.clearLayers()
      this.drawnItems.addLayer(e.layer)
      this._exportWkt(e.layer)
    })

    this.map.on(L.Draw.Event.EDITED, (e) => {
      e.layers.eachLayer((layer) => this._exportWkt(layer))
    })

    this.map.on(L.Draw.Event.DELETED, () => {
      this.wktFieldTarget.value = ""
    })
  }

  // Convertește polygon WGS84 din Leaflet → MultiPolygon WKT Stereo70
  _exportWkt(layer) {
    const latlngs = layer.getLatLngs()[0]
    const coords  = latlngs.map(ll => {
      const [x, y] = proj4("EPSG:4326", "EPSG:3844", [ll.lng, ll.lat])
      return `${x.toFixed(3)} ${y.toFixed(3)}`
    })
    // Închidem inelul
    const first = coords[0]
    const ring  = [...coords, first].join(", ")
    this.wktFieldTarget.value = `MULTIPOLYGON(((${ring})))`
  }

  // Afișează geometria existentă (WKT Stereo70) pe hartă ca WGS84
  _afiseazaGeometrieExistenta(wkt) {
    try {
      const match = wkt.match(/MULTIPOLYGON\s*\(\(\(([^)]+)\)\)\)/i)
      if (!match) return

      const perechi = match[1].trim().split(",").map(p => {
        const [x, y] = p.trim().split(/\s+/).map(Number)
        const [lng, lat] = proj4("EPSG:3844", "EPSG:4326", [x, y])
        return [lat, lng]
      })

      const polygon = L.polygon(perechi, { color: "#1d4ed8" })
      this.drawnItems.addLayer(polygon)
      this.map.fitBounds(polygon.getBounds(), { padding: [30, 30] })
    } catch (e) {
      console.warn("Nu s-a putut afișa geometria existentă:", e)
    }
  }
}
