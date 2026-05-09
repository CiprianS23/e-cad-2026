import { Controller } from "@hotwired/stimulus"

// Controlează harta principală cu parcele cadastrale + straturi ortofoto/OSM
export default class extends Controller {
  static values = {
    geojsonUrl:  String,
    mapproxyUrl: String
  }

  connect() {
    this.map = L.map(this.element, {
      center: [45.75, 24.9],
      zoom: 7,
      zoomControl: true
    })

    this._addLayers()
    this._loadParcele()
  }

  disconnect() {
    this.map?.remove()
  }

  _addLayers() {
    const osm = L.tileLayer(
      "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png",
      { attribution: "© OpenStreetMap contributors", maxZoom: 19 }
    )

    const layers = { "OpenStreetMap": osm }

    if (this.mapproxyUrlValue) {
      const ortoplan = L.tileLayer(
        `${this.mapproxyUrlValue}/tms/1.0.0/ortoplan/webmercator/{z}/{x}/{y}.jpeg`,
        {
          attribution: "© ANCPI – Ortofotoplan",
          maxZoom: 20,
          tms: true
        }
      )
      layers["Ortofotoplan (MapProxy)"] = ortoplan
      ortoplan.addTo(this.map)
    } else {
      osm.addTo(this.map)
    }

    this.parcelLayer = L.geoJSON(null, {
      style: this._parcelStyle.bind(this),
      onEachFeature: this._bindPopup.bind(this)
    })

    const overlays = { "Parcele cadastrale": this.parcelLayer }
    L.control.layers(layers, overlays, { collapsed: false }).addTo(this.map)
    this.parcelLayer.addTo(this.map)
  }

  async _loadParcele() {
    try {
      const res  = await fetch(this.geojsonUrlValue)
      const data = await res.json()
      this.parcelLayer.addData(data)

      if (this.parcelLayer.getLayers().length > 0) {
        this.map.fitBounds(this.parcelLayer.getBounds(), { padding: [40, 40] })
      }
    } catch (e) {
      console.warn("Nu s-au putut încărca parcelele:", e)
    }
  }

  _parcelStyle(feature) {
    const culori = {
      arabil:           "#22c55e",
      pasune:           "#84cc16",
      faneata:          "#a3e635",
      vie:              "#a855f7",
      livada:           "#f97316",
      padure:           "#15803d",
      curti_constructii:"#f59e0b",
      ape:              "#38bdf8",
      neproductiv:      "#9ca3af"
    }
    const status = feature.properties.status
    return {
      color:       status === "litigiu" ? "#dc2626" : "#1d4ed8",
      weight:      status === "litigiu" ? 2.5 : 1.5,
      fillColor:   culori[feature.properties.categoria_folosinta] || "#6b7280",
      fillOpacity: 0.35,
      dashArray:   status === "inactiv" ? "6 4" : null
    }
  }

  _bindPopup(feature, layer) {
    const p = feature.properties
    const url = `/parcele_cadastrale/${p.id}`
    layer.bindPopup(`
      <div class="map-popup">
        <strong>${p.numar_cadastral}</strong>
        <dl>
          <dt>Categorie</dt><dd>${p.categoria_folosinta || "—"}</dd>
          <dt>Suprafață</dt><dd>${p.suprafata_mp ? Number(p.suprafata_mp).toLocaleString("ro") + " mp" : "—"}</dd>
          <dt>Județ</dt><dd>${p.judet || "—"}</dd>
          <dt>Localitate</dt><dd>${p.localitate || "—"}</dd>
          <dt>Proprietar</dt><dd>${p.proprietar || "—"}</dd>
          <dt>Status</dt><dd><span class="badge badge-${p.status}">${p.status}</span></dd>
        </dl>
        <a href="${url}" class="btn btn-sm btn-primary" style="margin-top:6px">Detalii</a>
      </div>
    `, { maxWidth: 260 })

    layer.on("mouseover", () => layer.setStyle({ weight: 3, fillOpacity: 0.55 }))
    layer.on("mouseout",  () => this.parcelLayer.resetStyle(layer))
  }
}
