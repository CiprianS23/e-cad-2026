import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    geojsonUrl:      String,
    cgxmlGeojsonUrl: String,
    mapproxyUrl:     String
  }

  connect() {
    this.map = L.map(this.element, {
      center: [45.75, 24.9],
      zoom: 7,
      zoomControl: true
    })

    this._addLayers()
    this._loadParcele()
    this._loadCgxml()
  }

  disconnect() {
    this.map?.remove()
  }

  _addLayers() {
    const osm = L.tileLayer(
      "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png",
      { attribution: "© OpenStreetMap contributors", maxZoom: 19 }
    )

    const baseLayers = { "OpenStreetMap": osm }

    if (this.mapproxyUrlValue) {
      const ortoplan = L.tileLayer(
        `${this.mapproxyUrlValue}/tms/1.0.0/ortoplan/webmercator/{z}/{x}/{y}.jpeg`,
        { attribution: "© ANCPI – Ortofotoplan", maxZoom: 20, tms: true }
      )
      baseLayers["Ortofotoplan (MapProxy)"] = ortoplan
      ortoplan.addTo(this.map)
    } else {
      osm.addTo(this.map)
    }

    this.parcelLayer = L.geoJSON(null, {
      style: this._parcelStyle.bind(this),
      onEachFeature: this._bindParcelPopup.bind(this)
    })

    this.cgxmlLayer = L.geoJSON(null, {
      style: this._cgxmlStyle.bind(this),
      onEachFeature: this._bindCgxmlPopup.bind(this)
    })

    const overlays = {
      "Parcele cadastrale":  this.parcelLayer,
      "Imobile CGXML":       this.cgxmlLayer
    }

    L.control.layers(baseLayers, overlays, { collapsed: false }).addTo(this.map)
    this.parcelLayer.addTo(this.map)
    this.cgxmlLayer.addTo(this.map)
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

  async _loadCgxml() {
    if (!this.cgxmlGeojsonUrlValue) return
    try {
      const res  = await fetch(this.cgxmlGeojsonUrlValue)
      const data = await res.json()
      this.cgxmlLayer.addData(data)

      if (this.parcelLayer.getLayers().length === 0 && this.cgxmlLayer.getLayers().length > 0) {
        this.map.fitBounds(this.cgxmlLayer.getBounds(), { padding: [40, 40] })
      }
    } catch (e) {
      console.warn("Nu s-au putut încărca imobilele CGXML:", e)
    }
  }

  _parcelStyle(feature) {
    const culori = {
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
    const status = feature.properties.status
    return {
      color:       status === "litigiu" ? "#dc2626" : "#1d4ed8",
      weight:      status === "litigiu" ? 2.5 : 1.5,
      fillColor:   culori[feature.properties.categoria_folosinta] || "#6b7280",
      fillOpacity: 0.35,
      dashArray:   status === "inactiv" ? "6 4" : null
    }
  }

  _cgxmlStyle(feature) {
    const isBuilding = feature.properties.entity_type === "building"
    return {
      color:       isBuilding ? "#b91c1c" : "#92400e",
      weight:      isBuilding ? 1.5 : 2,
      fillColor:   isBuilding ? "#fca5a5" : "#fcd34d",
      fillOpacity: 0.45
    }
  }

  _bindParcelPopup(feature, layer) {
    const p = feature.properties
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
        <a href="/parcele_cadastrale/${p.id}" class="btn btn-sm btn-primary" style="margin-top:6px">Detalii</a>
      </div>
    `, { maxWidth: 260 })

    layer.on("mouseover", () => layer.setStyle({ weight: 3, fillOpacity: 0.55 }))
    layer.on("mouseout",  () => this.parcelLayer.resetStyle(layer))
  }

  _bindCgxmlPopup(feature, layer) {
    const p   = feature.properties
    const isBuilding = p.entity_type === "building"
    const title      = isBuilding ? `Construcție #${p.buildno ?? p.id}` : `Imobil`

    const fileLink = p.file_description_id
      ? `<a href="/cgxml_files/${p.file_description_id}" target="_blank">${p.filename || "—"}</a>`
      : (p.filename || "—")

    const vsClass = { valid: "badge-valid", errors: "badge-error", pending: "badge-secondary", in_progress: "badge-info" }
    const vsLabel = { valid: "Valid", errors: "Erori", pending: "În așteptare", in_progress: "În curs" }
    const errBadge = p.validation_status
      ? `<span class="badge ${vsClass[p.validation_status] || "badge-secondary"}">${vsLabel[p.validation_status] || p.validation_status}</span>`
        + (p.validation_errors_count   > 0 ? ` <span class="badge badge-error">${p.validation_errors_count} erori</span>` : "")
        + (p.validation_warnings_count > 0 ? ` <span class="badge badge-warning">${p.validation_warnings_count} avert.</span>` : "")
      : "—"

    const opLabel = {
      GENERAL_CADASTRE:     "Cadastru general",
      FIRST_REGISTRATION:   "Prima înscriere",
      UPDATE:               "Actualizare",
      CORRECTION:           "Corecție"
    }

    const destLabel = {
      CL: "Clădire locuință", IL: "Imobil locuință", CA: "Construcție auxiliară",
      CI: "Construcție industrială", IS: "Instituție/servicii", AN: "Anexă"
    }

    const mp  = (v) => v != null ? Number(v).toLocaleString("ro-RO", { maximumFractionDigits: 2 }) + " mp" : "—"
    const txt = (v) => v || "—"

    const entityRows = isBuilding ? `
      <tr><th>Nr. corp</th><td>${txt(p.buildno)}</td></tr>
      <tr><th>Destinație</th><td>${destLabel[p.buildingdestination] || txt(p.buildingdestination)}</td></tr>
      <tr><th>Niveluri</th><td>${txt(p.levelsno)}</td></tr>
      <tr><th>Suprafață măsurată</th><td>${mp(p.measuredarea)}</td></tr>
      <tr><th>Suprafață legală</th><td>${mp(p.parcellegalarea)}</td></tr>
      ${p.cadgenno ? `<tr><th>Nr. cadastral</th><td>${p.cadgenno}</td></tr>` : ""}
      ${p.e2identifier ? `<tr><th>Identificator E2</th><td>${p.e2identifier}</td></tr>` : ""}
      ${p.notes ? `<tr><th>Observații</th><td style="white-space:normal;max-width:200px">${p.notes}</td></tr>` : ""}
    ` : `
      <tr><th>Suprafață măsurată</th><td>${mp(p.measuredarea)}</td></tr>
      <tr><th>Suprafață legală parcelă</th><td>${mp(p.parcellegalarea)}</td></tr>
      ${p.cadgenno ? `<tr><th>Nr. cadastral general</th><td>${p.cadgenno}</td></tr>` : ""}
      ${p.cadsector ? `<tr><th>Sector cadastral</th><td>${p.cadsector}</td></tr>` : ""}
      ${p.e2identifier ? `<tr><th>Identificator E2</th><td>${p.e2identifier}</td></tr>` : ""}
      ${p.isnew != null ? `<tr><th>Imobil nou</th><td>${p.isnew ? "Da" : "Nu"}</td></tr>` : ""}
    `

    layer.bindPopup(`
      <div class="map-popup cgxml-popup">
        <div class="popup-title">${title}</div>
        <div class="popup-section-label">Fișier CGXML</div>
        <table class="popup-table">
          <tr><th>Fișier</th><td>${fileLink}</td></tr>
          <tr><th>Versiune</th><td>${txt(p.fileversion)}</td></tr>
          <tr><th>Tip operație</th><td>${opLabel[p.operationtype] || txt(p.operationtype)}</td></tr>
          <tr><th>Validare</th><td>${errBadge}</td></tr>
        </table>
        <div class="popup-section-label">${isBuilding ? "Construcție" : "Imobil"}</div>
        <table class="popup-table">
          ${entityRows}
        </table>
      </div>
    `, { maxWidth: 300 })

    layer.on("mouseover", () => layer.setStyle({ weight: 3, fillOpacity: 0.65 }))
    layer.on("mouseout",  () => this.cgxmlLayer.resetStyle(layer))
  }
}
