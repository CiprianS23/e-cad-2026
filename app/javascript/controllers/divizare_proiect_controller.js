import { Controller } from "@hotwired/stimulus"

// Floating toolbar pentru workflow „Divizare proiect parcelar".
// Faza 1 = persistare contururi multiple cu salvare explicită + listă completă
// afișată pe hartă (gri) + activ (galben).
export default class extends Controller {
  static outlets = ["harta-map"]
  static targets = [
    "phaseTab1", "phaseTab2", "phaseTab3", "phaseTab4", "phaseTab5",
    "panel1", "panel2", "panel3", "panel4", "panel5",
    "contourArea", "contourStatus", "contourName",
    "btnDrawContour", "btnResetContour", "btnSaveContour", "btnNextFrom1",
    "savedList", "btnLoadSelected", "btnDeleteSelected",
    // Faza 2 — CGXML fit
    "btnDetectCgxml", "btnApplyFit", "btnNextFrom2",
    "fitStatus", "fitList",
    // Faza 3 — Simulare + parcelare
    "btnRecomputeZones", "btnSimulate", "btnNextFrom3",
    "zoneStatus", "zoneInfo", "targetsTextarea", "simulateResult"
  ]

  connect() {
    this._state = {
      phase: 1,
      completed: new Set(),
      contourFeature: null,
      activeContourId: null
    }
    this._allContours = []  // ultima listă fetched (cu geometry)

    // Layer pentru conturul ACTIV (galben, distinctiv)
    this._activeSource = new ol.source.Vector()
    this._activeLayer  = new ol.layer.Vector({
      source: this._activeSource,
      style: () => new ol.style.Style({
        stroke: new ol.style.Stroke({ color: "#ca8a04", width: 2.5, lineDash: [8, 5] }),
        fill:   new ol.style.Fill({ color: "rgba(250, 204, 21, 0.18)" })
      }),
      zIndex: 855
    })

    // Layer pentru zonele rămase Faza 3 (contour - gis_imobile) — albastru pastel
    this._zonesSource = new ol.source.Vector()
    this._zonesLayer  = new ol.layer.Vector({
      source: this._zonesSource,
      style: (feature) => {
        const selected = feature.get("_selected") === true
        return [
          new ol.style.Style({
            stroke: new ol.style.Stroke({
              color: selected ? "#1d4ed8" : "#60a5fa",
              width: selected ? 3 : 2,
              lineDash: [6, 4]
            }),
            fill: new ol.style.Fill({
              color: selected ? "rgba(29, 78, 216, 0.25)" : "rgba(96, 165, 250, 0.10)"
            })
          }),
          new ol.style.Style({
            text: new ol.style.Text({
              text: `Z${feature.get("idx") || ""}\n${(feature.get("area") || 0).toFixed(0)} mp`,
              font: "11px sans-serif",
              fill:   new ol.style.Fill({ color: "#1e3a8a" }),
              stroke: new ol.style.Stroke({ color: "#fff", width: 2 })
            }),
            geometry: (f) => f.getGeometry().getInteriorPoint?.() || f.getGeometry()
          })
        ]
      },
      zIndex: 857
    })
    this._zones = []
    this._selectedZoneIdx = null

    // Layer pentru sub-geometrii Faza 2 (CGXML fitted) — verde solid
    this._fitSource = new ol.source.Vector()
    this._fitLayer  = new ol.layer.Vector({
      source: this._fitSource,
      style: (feature) => {
        const checked = feature.get("_checked") !== false
        return new ol.style.Style({
          stroke: new ol.style.Stroke({
            color: checked ? "#16a34a" : "#9ca3af",
            width: checked ? 2.5 : 1.5,
            lineDash: checked ? null : [4, 3]
          }),
          fill: new ol.style.Fill({
            color: checked ? "rgba(34, 197, 94, 0.28)" : "rgba(156, 163, 175, 0.12)"
          })
        })
      },
      zIndex: 858
    })
    this._fitCandidates = []

    // Layer pentru contururile SALVATE (gri, fundal pasiv)
    this._savedSource = new ol.source.Vector()
    this._savedLayer  = new ol.layer.Vector({
      source: this._savedSource,
      style: (feature) => [
        new ol.style.Style({
          stroke: new ol.style.Stroke({ color: "rgba(75, 85, 99, 0.7)", width: 1.5, lineDash: [4, 3] }),
          fill:   new ol.style.Fill({ color: "rgba(156, 163, 175, 0.08)" })
        }),
        new ol.style.Style({
          text: new ol.style.Text({
            text: feature.get("name") || "",
            font: "11px sans-serif",
            fill:   new ol.style.Fill({ color: "#374151" }),
            stroke: new ol.style.Stroke({ color: "#fff", width: 2 })
          }),
          geometry: (f) => f.getGeometry().getInteriorPoint?.() || f.getGeometry()
        })
      ],
      zIndex: 850
    })
  }

  initialize() {
    // Trigger-ul (buton în header sidebar) dispatcheaza un eveniment global
    // pentru a apela `open()` în mod curat — nu doar a seta hidden=false.
    this._openHandler = () => this.open()
    document.addEventListener("divizare-proiect:open", this._openHandler)
  }

  disconnect() {
    if (this._openHandler) document.removeEventListener("divizare-proiect:open", this._openHandler)
    this._cleanup()
  }

  hartaMapOutletConnected(outlet) {
    this._outlet = outlet
    if (outlet.map) this._attachToMap()
    else outlet.element.addEventListener("harta-map:ready", () => this._attachToMap(), { once: true })
  }

  _attachToMap() {
    this.map = this._outlet?.map
    if (!this.map) return
    this.map.addLayer(this._savedLayer)
    this.map.addLayer(this._zonesLayer)
    this.map.addLayer(this._fitLayer)
    this.map.addLayer(this._activeLayer)
    // Click pe zonă rămasă → selectează
    this._zoneClickKey = this.map.on("singleclick", (evt) => this._tryZoneClick(evt))
    if (!this.element.hidden) this._refreshSavedList()
  }

  _tryZoneClick(evt) {
    if (this._state.phase !== 3) return
    if (this._drawInteraction) return  // în mod desen, click-ul e pentru vertecși
    const feat = this.map.forEachFeatureAtPixel(evt.pixel, (f, layer) => {
      return layer === this._zonesLayer ? f : null
    })
    if (feat) {
      const idx = feat.get("idx")
      this._selectZone(idx)
    }
  }

  _selectZone(idx) {
    this._selectedZoneIdx = idx
    this._zonesSource.getFeatures().forEach(f => {
      f.set("_selected", f.get("idx") === idx)
    })
    this._zonesLayer.changed()
    const zone = this._zones.find(z => z.idx === idx)
    if (this.hasZoneInfoTarget && zone) {
      this.zoneInfoTarget.textContent = `Zonă selectată: Z${idx} · aria ${zone.area.toFixed(2)} mp`
    }
    this._maybeEnableSimulate()
  }

  // ── Toolbar visibility ───────────────────────────────────────────────────

  open() {
    this.element.hidden = false
    this._refreshSavedList()
    this._renderPhase()
  }

  close() {
    if (this._hasUnsavedActive() && !confirm("Conturul curent nu e salvat. Continui și pierzi desenul?")) return
    this._cleanup()
    this._state = { phase: 1, completed: new Set(), contourFeature: null, activeContourId: null }
    this._activeSource.clear()
    this._savedSource.clear()
    this._fitSource.clear()
    this._fitCandidates = []
    this._renderPhase()
    this.element.hidden = true
  }

  goToPhase(evt) {
    const target = parseInt(evt.currentTarget.dataset.phase, 10)
    if (!Number.isInteger(target)) return
    if (target > 1 && !this._state.completed.has(target - 1)) {
      this._setStatus(`Completează întâi Faza ${target - 1}.`, "warn"); return
    }
    this._state.phase = target
    this._renderPhase()
  }

  // ── Listă contururi salvate ─────────────────────────────────────────────

  async _refreshSavedList() {
    if (!this.hasSavedListTarget) return
    try {
      const res  = await fetch("/gis/contours")
      const data = await res.json()
      this._allContours = data.contours || []
      this._populateDropdown(this._allContours)
      this._renderSavedOnMap(this._allContours)
    } catch (e) {
      console.warn("[divizare] refresh saved list:", e)
    }
  }

  _populateDropdown(contours) {
    const sel = this.savedListTarget
    sel.innerHTML = ""
    const opt0 = document.createElement("option")
    opt0.value = ""
    opt0.textContent = contours.length
      ? `— alege un contur (${contours.length}) —`
      : "— niciunul salvat —"
    sel.appendChild(opt0)
    contours.forEach(c => {
      const o    = document.createElement("option")
      const area = Number(c.area) || 0
      const date = c.updated_at ? new Date(c.updated_at).toLocaleDateString("ro-RO") : "—"
      o.value       = String(c.id)
      o.textContent = `${c.name} (${area.toFixed(0)} mp · ${date})`
      sel.appendChild(o)
    })
  }

  _renderSavedOnMap(contours) {
    this._savedSource.clear()
    const fmt = new ol.format.GeoJSON()
    contours.forEach(c => {
      if (!c.geometry) return
      if (c.id === this._state.activeContourId) return  // activul e pe activeLayer
      const feat = fmt.readFeature(
        { type: "Feature", id: c.id, geometry: c.geometry, properties: { name: c.name, id: c.id } },
        { dataProjection: "EPSG:3844", featureProjection: "EPSG:3844" }
      )
      this._savedSource.addFeature(feat)
    })
  }

  async loadSelected() {
    const id = this.savedListTarget?.value
    if (!id) return
    if (this._hasUnsavedActive() && !confirm("Pierzi conturul curent nesalvat. Continui?")) return

    const c = this._allContours.find(x => String(x.id) === String(id))
    if (!c) return
    this._setActiveFromContour(c)
    this.map.getView().fit(this._state.contourFeature.getGeometry().getExtent(), { padding: [40, 40, 40, 40], duration: 400 })
    this._setStatus(`✓ Contur „${c.name}" încărcat.`, "ok")
  }

  _setActiveFromContour(c) {
    this._activeSource.clear()
    const fmt  = new ol.format.GeoJSON()
    const feat = fmt.readFeature(
      { type: "Feature", id: c.id, geometry: c.geometry, properties: { name: c.name } },
      { dataProjection: "EPSG:3844", featureProjection: "EPSG:3844" }
    )
    this._activeSource.addFeature(feat)
    this._state.contourFeature  = feat
    this._state.activeContourId = c.id
    this._state.completed.add(1)
    if (this.hasContourNameTarget) this.contourNameTarget.value = c.name
    this._renderSavedOnMap(this._allContours)  // re-render ca să elimini activul din layerul gri
    this._renderContourMeta()
    this._renderPhaseTabs()
  }

  async deleteSelected() {
    const id = this.savedListTarget?.value
    if (!id) return
    const label = this.savedListTarget.options[this.savedListTarget.selectedIndex]?.textContent || `#${id}`
    if (!confirm(`Ștergi conturul „${label}"?`)) return
    try {
      const res  = await fetch(`/gis/contours/${id}`, {
        method:  "DELETE",
        headers: { "X-CSRF-Token": this._csrf(), "Accept": "application/json" }
      })
      const data = await res.json()
      if (!data.ok) { this._setStatus("Nu am putut șterge.", "warn"); return }

      if (this._state.activeContourId === parseInt(id, 10)) {
        this._activeSource.clear()
        this._state.contourFeature  = null
        this._state.activeContourId = null
        this._state.completed.delete(1)
        this._renderContourMeta()
        this._renderPhaseTabs()
      }
      this._refreshSavedList()
      this._setStatus("Contur șters.", "ok")
    } catch (e) {
      this._setStatus(`Eroare ștergere: ${e.message}`, "warn")
    }
  }

  // ── Faza 1: Desen ───────────────────────────────────────────────────────

  startDrawContour() {
    if (!this.map) { this._setStatus("Harta nu e gata.", "warn"); return }
    this._cancelDraw()
    // Curățăm DOAR conturul activ în lucru — contururile salvate rămân vizibile (gri)
    this._activeSource.clear()
    this._state.contourFeature  = null
    this._state.activeContourId = null
    this._state.completed.delete(1)

    // Ascunde popup-urile + închide popup existent (folosim metoda publică)
    if (this._outlet?.setDigitizing) this._outlet.setDigitizing(true)
    else if (this._outlet) this._outlet._digitizing = true

    // Style ca FUNCȚIE — OL Draw creează 3 features interne (Polygon, LineString, Point);
    // funcția returnează un Style cu image (Circle) → vizibil pe Point la cursor.
    const sketchStyle = () => new ol.style.Style({
      stroke: new ol.style.Stroke({ color: "#ca8a04", width: 3, lineDash: [8, 5] }),
      fill:   new ol.style.Fill({ color: "rgba(250, 204, 21, 0.20)" }),
      image:  new ol.style.Circle({
        radius: 6,
        fill:   new ol.style.Fill({ color: "#1d4ed8" }),
        stroke: new ol.style.Stroke({ color: "#fff", width: 2 })
      })
    })

    try {
      this._drawInteraction = new ol.interaction.Draw({
        source: this._activeSource,
        type:   "Polygon",
        style:  sketchStyle
      })
      this._drawInteraction.on("drawend", (evt) => this._onContourDrawn(evt))
      this.map.addInteraction(this._drawInteraction)
      console.debug("[divizare] Draw added; interactions count:", this.map.getInteractions().getLength())
    } catch (e) {
      console.error("[divizare] Draw setup eșuat:", e)
      this._setStatus(`Eroare Draw: ${e.message}`, "warn")
      return
    }

    // OSnap dezactivat temporar pentru diagnostic — îl reactivăm după ce confirmăm
    // că Draw funcționează. Dacă features-urile colectate au geometrii invalide,
    // Snap aruncă în adâncime și blochează rendering-ul sketch-ului.
    // try {
    //   this._snapInteraction = new ol.interaction.Snap({
    //     features: this._collectSnapFeatures(),
    //     pixelTolerance: 12
    //   })
    //   this.map.addInteraction(this._snapInteraction)
    // } catch (e) { console.warn("[divizare] Snap setup eșuat:", e) }

    if (!this._keyHandler) {
      this._keyHandler = (e) => { if (e.key === "Escape") this._cancelDraw() }
      document.addEventListener("keydown", this._keyHandler)
    }

    this._setStatus("Desenează: click vertecși (snap activ), dublu-click închide, Esc anulează.", "info")
    if (this.hasBtnDrawContourTarget)  this.btnDrawContourTarget.disabled = true
    if (this.hasBtnResetContourTarget) this.btnResetContourTarget.disabled = false
    if (this.hasBtnSaveContourTarget)  this.btnSaveContourTarget.disabled = true
  }

  resetContour() {
    if (this._state.contourFeature && !confirm("Ștergi conturul curent? (Cel salvat în DB nu se afectează.)")) return
    this._cancelDraw()
    this._activeSource.clear()
    this._state.contourFeature  = null
    this._state.activeContourId = null
    this._state.completed.delete(1)
    this._renderContourMeta()
    this._setStatus("Resetat.", "")
    this._renderPhaseTabs()
    if (this.hasBtnSaveContourTarget) this.btnSaveContourTarget.disabled = true
  }

  _onContourDrawn(evt) {
    const others = this._activeSource.getFeatures().filter(f => f !== evt.feature)
    others.forEach(f => this._activeSource.removeFeature(f))
    this._state.contourFeature = evt.feature

    setTimeout(() => this._cancelDraw(), 30)

    this._renderContourMeta()
    if (this.hasBtnSaveContourTarget) this.btnSaveContourTarget.disabled = false
    this._setStatus('✓ Contur desenat. Apasă „💾 Salvează" pentru a-l persista.', "ok")
  }

  // ── SALVARE EXPLICITĂ ────────────────────────────────────────────────────

  async saveContour() {
    if (!this._state.contourFeature) { this._setStatus("Nu există contur de salvat.", "warn"); return }

    let name = this.contourNameTarget?.value?.trim()
    if (!name) {
      name = prompt(
        "Numele conturului:",
        `Contur ${new Date().toLocaleString("ro-RO", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" })}`
      )
      if (!name) return
      if (this.hasContourNameTarget) this.contourNameTarget.value = name
    }

    const wkt = this._featureToWkt(this._state.contourFeature)

    try {
      // Update dacă există deja id, altfel create
      const isUpdate = !!this._state.activeContourId
      const url     = isUpdate ? `/gis/contours/${this._state.activeContourId}` : "/gis/contours"
      const method  = isUpdate ? "PATCH" : "POST"
      this._setStatus(isUpdate ? "Actualizez…" : "Salvez…", "info")

      const res = await fetch(url, {
        method,
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf() },
        body: JSON.stringify({ name, geom_wkt: wkt })
      })
      const data = await res.json()
      if (!data.ok) {
        this._setStatus(`Eroare salvare: ${(data.errors || []).join(", ")}`, "warn")
        return
      }
      this._state.activeContourId = data.contour.id
      this._state.completed.add(1)
      this._renderContourMeta()
      this._renderPhaseTabs()
      this._refreshSavedList()
      this._setStatus(`✓ Salvat „${data.contour.name}" (id=${data.contour.id}).`, "ok")
      if (this.hasBtnSaveContourTarget) this.btnSaveContourTarget.disabled = false
    } catch (e) {
      this._setStatus(`Eroare rețea: ${e.message}`, "warn")
    }
  }

  renameActive() {
    // No-op live; aplicarea numelui se face la save sau prin saveContour
    if (this._state.activeContourId && this.hasContourNameTarget) {
      this.saveContour()
    }
  }

  // ── Helpers desen ───────────────────────────────────────────────────────

  _cancelDraw() {
    if (this._drawInteraction) {
      this.map.removeInteraction(this._drawInteraction)
      this._drawInteraction = null
    }
    if (this._snapInteraction) {
      this.map.removeInteraction(this._snapInteraction)
      this._snapInteraction = null
    }
    if (this._keyHandler) {
      document.removeEventListener("keydown", this._keyHandler)
      this._keyHandler = null
    }
    if (this._outlet?.setDigitizing) this._outlet.setDigitizing(false)
    else if (this._outlet) this._outlet._digitizing = false
    if (this.hasBtnDrawContourTarget) this.btnDrawContourTarget.disabled = false
  }

  _collectSnapFeatures() {
    const all = []
    const sources = [
      this._outlet?.parcelLayer?.getSource?.(),
      this._outlet?.cladiriLayer?.getSource?.(),
      this._outlet?.cgxmlLayer?.getSource?.(),
      this._savedSource
    ]
    sources.forEach(src => { if (src) all.push(...src.getFeatures()) })
    return new ol.Collection(all)
  }

  nextFromPhase1() {
    if (!this._state.completed.has(1)) {
      this._setStatus("Salvează conturul mai întâi.", "warn"); return
    }
    this._state.phase = 2
    this._renderPhase()
  }

  // ── Faza 2: CGXML fit ────────────────────────────────────────────────────

  async detectCgxml() {
    const contourId = this._state.activeContourId
    if (!contourId) { this._setFitStatus("Selectează un contur salvat (Faza 1).", "warn"); return }

    this._setFitStatus("Caut imobile CGXML în contur…", "info")
    try {
      const res = await fetch("/gis/imobile/fit_preview", {
        method:  "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf() },
        body:    JSON.stringify({ contour_id: contourId })
      })
      const data = await res.json()
      if (!data.ok) { this._setFitStatus(`Eroare: ${data.error || res.status}`, "warn"); return }

      this._fitCandidates = data.candidates || []
      this._fitCandidates.forEach(c => c._checked = true)  // default toate bifate
      this._renderFitOnMap()
      this._renderFitList()

      const n = this._fitCandidates.length
      this._setFitStatus(
        n === 0 ? "Niciun imobil CGXML nu intersectează conturul." : `Găsite ${n} imobile (toate bifate implicit).`,
        n > 0 ? "ok" : "warn"
      )
      if (this.hasBtnApplyFitTarget) this.btnApplyFitTarget.disabled = n === 0
    } catch (e) {
      this._setFitStatus(`Eroare rețea: ${e.message}`, "warn")
    }
  }

  toggleFitCandidate(evt) {
    const landId = parseInt(evt.currentTarget.dataset.landId, 10)
    const cand   = this._fitCandidates.find(c => c.land_id === landId)
    if (!cand) return
    cand._checked = evt.currentTarget.checked
    // Actualizăm stilul feature-ului pe hartă
    const feat = this._fitSource.getFeatures().find(f => f.get("land_id") === landId)
    if (feat) {
      feat.set("_checked", cand._checked)
      this._fitLayer.changed()
    }
  }

  zoomToFit(evt) {
    const landId = parseInt(evt.currentTarget.dataset.landId, 10)
    const feat   = this._fitSource.getFeatures().find(f => f.get("land_id") === landId)
    if (!feat) return
    const extent = feat.getGeometry().getExtent()
    this.map.getView().fit(extent, { padding: [60, 60, 60, 60], duration: 400, maxZoom: 18 })
  }

  async applyFit() {
    const contourId = this._state.activeContourId
    if (!contourId) return
    const accepted = this._fitCandidates.filter(c => c._checked)
    if (accepted.length === 0) { this._setFitStatus("Bifează cel puțin un imobil.", "warn"); return }
    if (!confirm(`Aplici corecția pentru ${accepted.length} imobile CGXML?\nGeometria corectată se salvează în gis_imobile (source=cgxml_fit). Originalul în CGXML rămâne intact.`)) return

    this._setFitStatus("Aplic corecția…", "info")
    this.btnApplyFitTarget && (this.btnApplyFitTarget.disabled = true)
    try {
      const res = await fetch("/gis/imobile/fit_apply", {
        method:  "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf() },
        body:    JSON.stringify({ contour_id: contourId, land_ids: accepted.map(c => c.land_id) })
      })
      const data = await res.json()
      if (!data.ok) {
        this._setFitStatus(`Eroare: ${data.error || res.status}`, "warn")
        if (data.skipped) console.error(data.skipped)
        return
      }
      this._setFitStatus(`✓ Create/actualizate ${data.created.length} imobile.`, "ok")
      this._state.completed.add(2)
      this._renderPhaseTabs()
    } catch (e) {
      this._setFitStatus(`Eroare rețea: ${e.message}`, "warn")
    } finally {
      this.btnApplyFitTarget && (this.btnApplyFitTarget.disabled = false)
    }
  }

  nextFromPhase2() {
    if (!this._state.completed.has(2)) { this._setFitStatus("Aplică Faza 2 mai întâi.", "warn"); return }
    this._state.phase = 3
    this._renderPhase()
    this.recomputeZones()  // pre-load zonele rămase
  }

  // ── Faza 3: zone rămase + simulare fit ──────────────────────────────────

  async recomputeZones() {
    const contourId = this._state.activeContourId
    if (!contourId) { this._setZoneStatus("Lipsește conturul activ.", "warn"); return }

    this._setZoneStatus("Calculez zonele rămase…", "info")
    try {
      const res  = await fetch("/gis/imobile/remaining_zones", {
        method:  "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf() },
        body:    JSON.stringify({ contour_id: contourId })
      })
      const data = await res.json()
      if (!data.ok) { this._setZoneStatus(`Eroare: ${data.error || res.status}`, "warn"); return }

      this._zones = data.zones || []
      this._selectedZoneIdx = null
      this._renderZonesOnMap()
      const n = this._zones.length
      const total = this._zones.reduce((a, z) => a + z.area, 0)
      this._setZoneStatus(
        n === 0
          ? "Conturul e complet acoperit de imobilele aplicate. Nimic de parcelat."
          : `${n} zon${n === 1 ? "ă" : "e"} rămase · total ${total.toFixed(0)} mp. Click pe o zonă pe hartă pentru a o selecta.`,
        n === 0 ? "warn" : "ok"
      )
      if (this.hasZoneInfoTarget) this.zoneInfoTarget.textContent = ""
      this._maybeEnableSimulate()
    } catch (e) {
      this._setZoneStatus(`Eroare rețea: ${e.message}`, "warn")
    }
  }

  _renderZonesOnMap() {
    this._zonesSource.clear()
    const fmt = new ol.format.GeoJSON()
    this._zones.forEach(z => {
      if (!z.geometry) return
      const feat = fmt.readFeature(
        { type: "Feature", geometry: z.geometry, properties: {} },
        { dataProjection: "EPSG:3844", featureProjection: "EPSG:3844" }
      )
      feat.set("idx",  z.idx)
      feat.set("area", z.area)
      feat.set("_selected", false)
      this._zonesSource.addFeature(feat)
    })
  }

  targetsTextareaChanged() { this._maybeEnableSimulate() }

  _readTargets() {
    if (!this.hasTargetsTextareaTarget) return []
    return this.targetsTextareaTarget.value
      .split(/[\n,;\s]+/)
      .map(s => s.trim().replace(",", "."))
      .filter(Boolean)
      .map(Number)
      .filter(n => Number.isFinite(n) && n > 0)
  }

  _maybeEnableSimulate() {
    const ok = this._selectedZoneIdx != null && this._readTargets().length > 0
    if (this.hasBtnSimulateTarget) this.btnSimulateTarget.disabled = !ok
  }

  async simulate() {
    const idx = this._selectedZoneIdx
    const zone = this._zones.find(z => z.idx === idx)
    const targets = this._readTargets()
    if (!zone || targets.length === 0) return

    try {
      const res = await fetch("/gis/imobile/simulate_fit", {
        method:  "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf() },
        body:    JSON.stringify({ zone_area: zone.area, target_areas: targets })
      })
      const data = await res.json()
      if (!data.ok) { this._setZoneStatus(`Eroare: ${data.error}`, "warn"); return }
      this._renderSimulateResult(data, zone)
      this._state.completed.add(3)
      this._renderPhaseTabs()
    } catch (e) {
      this._setZoneStatus(`Eroare rețea: ${e.message}`, "warn")
    }
  }

  _renderSimulateResult(d, zone) {
    if (!this.hasSimulateResultTarget) return
    const verdictText = {
      perfect:           "✓ FIT PERFECT — toate parcelele încap exact",
      fits_with_surplus: `✓ Încap toate · surplus ${d.surplus_mp.toFixed(0)} mp (${((1 - d.fill_ratio) * 100).toFixed(1)}% rămâne nefolosit)`,
      overflow:          `✗ NU ÎNCAP — depășește cu ${d.deficit_mp.toFixed(0)} mp (${((d.fill_ratio - 1) * 100).toFixed(1)}% peste)`
    }[d.verdict]
    const verdictColor = d.verdict === "overflow" ? "#dc2626" : "#16a34a"

    this.simulateResultTarget.innerHTML = `
      <div style="border:1px solid #e5e7eb;border-radius:6px;padding:8px;margin-top:6px;background:#fafafa">
        <div style="font-weight:600;color:${verdictColor};margin-bottom:4px">${verdictText}</div>
        <table style="width:100%;font-size:11px;border-collapse:collapse">
          <tr><td>Zonă Z${d.target_count > 0 ? zone.idx : "—"}</td><td style="text-align:right">${d.zone_area.toFixed(2)} mp</td></tr>
          <tr><td>Suma țintă (${d.target_count} parcele)</td><td style="text-align:right">${d.target_sum.toFixed(2)} mp</td></tr>
          <tr><td>Diferență</td><td style="text-align:right;color:${d.diff < 0 ? "#dc2626" : "#16a34a"}">${d.diff > 0 ? "+" : ""}${d.diff.toFixed(2)} mp</td></tr>
          <tr><td>Fill ratio</td><td style="text-align:right">${(d.fill_ratio * 100).toFixed(1)}%</td></tr>
          <tr><td>Țintă min / med / max</td><td style="text-align:right">${d.min_target} / ${d.avg_target} / ${d.max_target}</td></tr>
        </table>
      </div>
    `
    this.simulateResultTarget.hidden = false
  }

  nextFromPhase3() {
    if (!this._state.completed.has(3)) { this._setZoneStatus("Rulează cel puțin o simulare.", "warn"); return }
    this._state.phase = 4
    this._renderPhase()
  }

  _setZoneStatus(msg, kind) {
    if (!this.hasZoneStatusTarget) return
    this.zoneStatusTarget.textContent = msg
    this.zoneStatusTarget.style.color = {
      ok:   "#16a34a",
      warn: "#dc2626",
      info: "#2563eb"
    }[kind] || "#6b7280"
  }

  _renderFitOnMap() {
    this._fitSource.clear()
    const fmt = new ol.format.GeoJSON()
    this._fitCandidates.forEach(c => {
      if (!c.geometry) return
      const feat = fmt.readFeature(
        { type: "Feature", geometry: c.geometry, properties: {} },
        { dataProjection: "EPSG:3844", featureProjection: "EPSG:3844" }
      )
      feat.set("land_id", c.land_id)
      feat.set("_checked", c._checked !== false)
      this._fitSource.addFeature(feat)
    })
  }

  _renderFitList() {
    if (!this.hasFitListTarget) return
    const rows = this._fitCandidates.map(c => {
      const label = c.cadgenno || c.e2identifier || `Land #${c.land_id}`
      const diffColor = Math.abs(c.area_diff) < 0.5 ? "#16a34a" : "#ea580c"
      const checkedAttr = c._checked === false ? "" : "checked"
      return `
        <li style="padding:4px 0;border-bottom:1px solid #f3f4f6;display:flex;align-items:center;gap:6px;font-size:11px">
          <input type="checkbox" ${checkedAttr}
                 data-land-id="${c.land_id}"
                 data-action="change->divizare-proiect#toggleFitCandidate">
          <span style="flex:1">
            <strong>${label}</strong>
            <span style="color:#6b7280">${c.filename || ""}</span><br>
            <span style="color:#374151">orig: ${c.original_area.toFixed(0)} mp · fit: ${c.fitted_area.toFixed(0)} mp ·
              <span style="color:${diffColor}">dif ${c.area_diff > 0 ? "+" : ""}${c.area_diff.toFixed(2)}</span>
            </span>
          </span>
          <button type="button" class="btn btn-outline btn-sm"
                  style="padding:1px 6px;font-size:11px"
                  data-land-id="${c.land_id}"
                  data-action="click->divizare-proiect#zoomToFit"
                  title="Zoom la imobil">🔍</button>
        </li>`
    }).join("")
    this.fitListTarget.innerHTML = rows
  }

  _setFitStatus(msg, kind) {
    if (!this.hasFitStatusTarget) return
    this.fitStatusTarget.textContent = msg
    this.fitStatusTarget.style.color = {
      ok:   "#16a34a",
      warn: "#dc2626",
      info: "#2563eb"
    }[kind] || "#6b7280"
  }

  // ── Rendering ────────────────────────────────────────────────────────────

  _renderPhase() {
    this._renderPhaseTabs()
    ;[1, 2, 3, 4, 5].forEach(p => {
      const panel = this[`hasPanel${p}Target`] ? this[`panel${p}Target`] : null
      if (panel) panel.classList.toggle("is-active", p === this._state.phase)
    })
    if (this._state.phase === 1) this._renderContourMeta()
  }

  _renderPhaseTabs() {
    [1, 2, 3, 4, 5].forEach(p => {
      const tab = this[`hasPhaseTab${p}Target`] ? this[`phaseTab${p}Target`] : null
      if (!tab) return
      tab.classList.toggle("is-active", p === this._state.phase)
      tab.classList.toggle("is-done", this._state.completed.has(p))
      if (p > 1) tab.disabled = !this._state.completed.has(p - 1)
    })
    if (this.hasBtnNextFrom1Target) {
      this.btnNextFrom1Target.disabled = !this._state.completed.has(1)
    }
  }

  _renderContourMeta() {
    if (!this.hasContourAreaTarget) return
    const f = this._state.contourFeature
    if (!f) { this.contourAreaTarget.textContent = "—"; return }
    const area = Math.abs(f.getGeometry().getArea())
    const tag  = this._state.activeContourId ? ` · id=${this._state.activeContourId}` : " · NESALVAT"
    this.contourAreaTarget.textContent = `${area.toFixed(2)} mp${tag}`
  }

  _setStatus(msg, kind) {
    if (!this.hasContourStatusTarget) return
    this.contourStatusTarget.textContent = msg
    this.contourStatusTarget.style.color = {
      ok:   "#16a34a",
      warn: "#dc2626",
      info: "#2563eb"
    }[kind] || "#6b7280"
  }

  _hasUnsavedActive() {
    return !!this._state.contourFeature && !this._state.activeContourId
  }

  _featureToWkt(feature) {
    return new ol.format.WKT().writeFeature(feature, { decimals: 6 })
  }

  _csrf() { return document.querySelector('[name="csrf-token"]')?.content ?? "" }

  _cleanup() {
    this._cancelDraw()
  }
}
