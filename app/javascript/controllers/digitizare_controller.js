import { Controller } from "@hotwired/stimulus"

const FMT  = (n) => Number(n).toLocaleString("ro-RO", { minimumFractionDigits: 3, maximumFractionDigits: 3 })
const FMT2 = (n) => Number(n).toLocaleString("ro-RO", { minimumFractionDigits: 2, maximumFractionDigits: 2 })

export default class extends Controller {
  static outlets = ["harta-map"]

  static values = {
    calcUrl:       String,
    verificaUrl:   String,
    exportDxfUrl:  String,
    locateUatUrl:  String,
    snapTolerance: { type: Number, default: 15 },
    editKind:      String,
    editId:        String,
    saveBatchUrl:  String,
    cleanupUrl:    String,
    bufferDrumUrl: String,
    saveDrumUrl:   String
  }

  static targets = [
    "panel", "panelBody", "editTopoMirror",
    "snapSlider", "snapToleranceVal", "snapModes",
    "metricSnapToggle", "metricSnapSlider", "metricSnapVal",
    "mapToolbar", "multiSelectBadge",
    "btnStart", "btnEdit", "btnDelete", "btnMove", "btnRotate", "btnClose", "btnUndo", "btnRedo", "btnAudit", "auditList",
    "btnLineDigitize",
    "cleanupSlider", "cleanupVal", "btnCleanup", "btnCleanupViewport", "cleanupResult",
    "btnMultiSelect", "btnPolygonSelect", "btnCancelAll", "multiCountBadge", "multiSelectInfo",
    "dxfFileInput", "dxfMapping",
    "btnExportZone", "btnExportZonePoly", "btnExportZoneSubmit", "exportFormat",
    "exportLayerParcele", "exportLayerCladiri", "exportStatus",
    "statusBar",
    "inputX", "inputY",
    "areaCalc", "areaAct", "areaDiff",
    "topologyMsg",
    "wktField", "saveForm", "saveAreaField",
    "wktFieldCladire", "saveFormCladire", "saveAreaFieldCladire",
    "formParcela", "formCladire",
    "btnEntityParcela", "btnEntityCladire",
    "cmdInput", "cmdHint",
    "snapToggle", "orthoToggle",
    "statusX", "statusY", "statusScale", "statusArea"
  ]

  // ── Lifecycle ────────────────────────────────────────────────────────────

  connect() {
    this._verts             = []
    this._areaCalc          = 0
    this._areaDebounce      = null
    this._topoDebounce      = null
    this._entityType        = "parcela"
    this._snapEnabled       = true
    this._orthoEnabled      = false
    // Persistă moduri OSNAP via localStorage — la refresh utilizatorul găsește
    // aceleași moduri active (default endpoint+midpoint dacă lipsesc).
    const savedSnapModes = (() => {
      try {
        const raw = localStorage.getItem("harta:snapModes")
        if (!raw) return null
        const arr = JSON.parse(raw)
        return Array.isArray(arr) ? arr : null
      } catch (_) { return null }
    })()
    this._snapModes         = new Set(savedSnapModes || ["endpoint", "midpoint"])
    // Snap metric — `_metricSnap.enabled` true → pixelTolerance se recalculează
    // ca metricValue / view.getResolution() la fiecare _refreshSnap și la
    // change:resolution; valoare persistată via localStorage.
    const savedMetric = (() => {
      try { return JSON.parse(localStorage.getItem("harta:metricSnap") || "null") } catch (_) { return null }
    })()
    this._metricSnap = {
      enabled: !!(savedMetric && savedMetric.enabled),
      meters:  Number((savedMetric && savedMetric.meters)) || 0.5
    }
    this._polygonValid      = false
    this._polygonSimple     = false
    this._topologyIssues    = []
    this._topologyHasErrors = false

    this._drawSource = new ol.source.Vector()
    this._drawLayer  = new ol.layer.Vector({
      source: this._drawSource,
      style:  this._drawStyle.bind(this),
      properties: { name: "digitizare" }
    })

    // Layer dedicat pentru AXA drumului (centerline). Vertecșii ei sunt editabili
    // → la modificare regenerează banda drumului. Banda în sine (în _drawSource) e
    // doar pentru afișare, nu se editează direct.
    this._axisSource = new ol.source.Vector()
    this._axisLayer  = new ol.layer.Vector({
      source: this._axisSource,
      style: () => new ol.style.Style({
        stroke: new ol.style.Stroke({ color: "#ea580c", width: 2.5, lineDash: [8, 4] }),
        image: new ol.style.Circle({
          radius: 5,
          fill:   new ol.style.Fill({ color: "#ea580c" }),
          stroke: new ol.style.Stroke({ color: "#fff", width: 1.5 })
        })
      }),
      properties: { name: "drum-axis" },
      zIndex: 1300
    })

    // Zonă de prag alipire — inel între limita drumului și (limita + snap_dist).
    // Vizual semi-transparent ca utilizatorul să vadă zona unde vecinii vor fi
    // alipiți. Sub axis în z-index ca să nu acopere axa editabilă.
    this._snapZoneSource = new ol.source.Vector()
    this._snapZoneLayer  = new ol.layer.Vector({
      source: this._snapZoneSource,
      style: () => new ol.style.Style({
        fill:   new ol.style.Fill({ color: "rgba(234, 88, 12, 0.15)" }),
        stroke: new ol.style.Stroke({ color: "#ea580c", width: 1.5, lineDash: [4, 3] })
      }),
      properties: { name: "drum-snap-zone" },
      zIndex: 1250
    })

    // Layer separat pentru evidențierea conflictelor topologice (overlap, sliver, vertex-off)
    this._topoSource = new ol.source.Vector()
    this._topoLayer  = new ol.layer.Vector({
      source: this._topoSource,
      style:  this._topoStyle.bind(this),
      properties: { name: "topologie-issues" },
      zIndex: 1000
    })

    // Layer dedicat pentru audit topologic global — geometriile issue-urilor
    // de pe întreaga hartă (overlap-uri, clădiri multi-parcela, etc.)
    this._auditSource = new ol.source.Vector()
    this._auditLayer  = new ol.layer.Vector({
      source: this._auditSource,
      style:  (feat) => {
        const sev = feat.get("severity") || "error"
        return new ol.style.Style({
          stroke: new ol.style.Stroke({
            color: sev === "error" ? "#dc2626" : "#d97706",
            width: 3,
            lineDash: sev === "warning" ? [6, 3] : null
          }),
          fill: new ol.style.Fill({
            color: sev === "error" ? "rgba(220, 38, 38, 0.35)" : "rgba(217, 119, 6, 0.25)"
          })
        })
      },
      properties: { name: "audit-topologie" },
      zIndex: 1050
    })

    // Vertexii poligonului editat: PĂTRAT roșu (#dc2626).
    // Vertexii vecinilor (editabili sau doar vizualizare): CERC.
    // - Portocaliu (#f59e0b): vecini editabili (topology-aware)
    // - Gri-bleu (#64748b): vecini doar pentru vizualizare (CGXML)
    this._editVertexSource = new ol.source.Vector()
    this._editVertexLayer  = new ol.layer.Vector({
      source: this._editVertexSource,
      style:  (feat) => {
        // Pivot rotație — cerc mare portocaliu cu border alb gros (distinct)
        if (feat.get("rotatePivot")) {
          return new ol.style.Style({
            image: new ol.style.Circle({
              radius: 10,
              fill:   new ol.style.Fill({ color: "#ea580c" }),
              stroke: new ol.style.Stroke({ color: "#fff", width: 3 })
            }),
            zIndex: 10
          })
        }
        // Marker move — punct de bază (verde) sau destinație (albastru)
        if (feat.get("moveMarker")) {
          const isBase = feat.get("moveMarker") === "base"
          return new ol.style.Style({
            image: new ol.style.Circle({
              radius: 8,
              fill:   new ol.style.Fill({ color: isBase ? "#16a34a" : "#1d4ed8" }),
              stroke: new ol.style.Stroke({ color: "#fff", width: 2.5 })
            }),
            zIndex: 10
          })
        }
        // Snap hover — cerc mare cyan, indicator clar pentru snap activ
        if (feat.get("snapHover")) {
          return new ol.style.Style({
            image: new ol.style.Circle({
              radius: 14,
              fill:   new ol.style.Fill({ color: "rgba(6, 182, 212, 0.30)" }),
              stroke: new ol.style.Stroke({ color: "#06b6d4", width: 3 })
            }),
            zIndex: 12
          })
        }
        const isVisual   = feat.get("visualNeighbor")
        const isNeighbor = feat.get("neighborVertex")
        if (isVisual || isNeighbor) {
          const color  = isVisual ? "#64748b" : "#f59e0b"
          const radius = isVisual ? 4 : 5
          return new ol.style.Style({
            image: new ol.style.Circle({
              radius,
              fill:   new ol.style.Fill({ color }),
              stroke: new ol.style.Stroke({ color: "#fff", width: 1.5 })
            })
          })
        }
        // Primary — pătrat roșu, aliniat pe axe
        return new ol.style.Style({
          image: new ol.style.RegularShape({
            points: 4,
            radius: 6,
            angle:  Math.PI / 4,
            fill:   new ol.style.Fill({ color: "#dc2626" }),
            stroke: new ol.style.Stroke({ color: "#fff", width: 1.5 })
          })
        })
      },
      properties: { name: "edit-vertices" },
      zIndex: 1100
    })

    // Etichete cu lungimea muchiilor (în metri Stereo70), plasate în interiorul
    // poligonului — utile pentru verificarea distanțelor între vertecși la edit.
    // Tot aici: o etichetă centrală cu suprafața totală (flag `areaLabel:true`).
    this._editEdgeLabelsSource = new ol.source.Vector()
    this._editEdgeLabelsLayer  = new ol.layer.Vector({
      source: this._editEdgeLabelsSource,
      style: (feat) => {
        if (feat.get("areaLabel")) {
          const a = feat.get("area") || 0
          const text = a >= 1000 ? `${a.toFixed(0)} mp` : `${a.toFixed(2)} mp`
          return new ol.style.Style({
            text: new ol.style.Text({
              text,
              font:        "700 15px system-ui, sans-serif",
              fill:        new ol.style.Fill({ color: "#0f172a" }),
              stroke:      new ol.style.Stroke({ color: "#ffffff", width: 4 }),
              textAlign:   "center",
              overflow:    true,
              backgroundFill:   new ol.style.Fill({ color: "rgba(255,255,255,0.85)" }),
              backgroundStroke: new ol.style.Stroke({ color: "#1f2937", width: 1 }),
              padding:     [4, 6, 4, 6]
            })
          })
        }
        const d = feat.get("distance") || 0
        const text = d >= 100 ? `${d.toFixed(1)} m` : `${d.toFixed(2)} m`
        return new ol.style.Style({
          text: new ol.style.Text({
            text,
            font:      "600 11px system-ui, sans-serif",
            fill:      new ol.style.Fill({ color: "#1f2937" }),
            stroke:    new ol.style.Stroke({ color: "#ffffff", width: 3 }),
            textAlign: "center",
            overflow:  true,
            rotation:  feat.get("rotation") || 0
          })
        })
      },
      properties: { name: "edit-edge-labels" },
      zIndex: 1090
    })

    this._onKeyDown = (evt) => this._handleGlobalKey(evt)
    document.addEventListener("keydown", this._onKeyDown)

    // Reflectă în UI modurile OSNAP restaurate din localStorage.
    this._syncSnapModeCheckboxes()
    this._syncMetricSnapUI()
    this._restoreToolbarPosition()
    this._updateToolbarVisibility()
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKeyDown)
    this._teardown()
  }

  hartaMapOutletConnected(outlet) {
    this._hartaMap = outlet
    if (outlet.map) {
      this._attachToMap()
    } else {
      outlet.element.addEventListener("harta-map:ready", () => this._attachToMap(), { once: true })
    }
    // Ascultăm evenimentele de selecție feature de la harta-map
    outlet.element.addEventListener("harta-map:feature-selected",   (e) => this._onFeatureSelected(e.detail))
    outlet.element.addEventListener("harta-map:feature-deselected", ()  => this._onFeatureSelected(null))
    outlet.element.addEventListener("harta-map:multi-selection-changed", (e) => this._onMultiSelectionChanged(e.detail))
    outlet.element.addEventListener("harta-map:multi-select-mode",       (e) => this._onMultiSelectMode(e.detail))
    outlet.element.addEventListener("harta-map:polygon-select-mode",     (e) => this._onPolygonSelectMode(e.detail))
  }

  hartaMapOutletDisconnected() { this._teardown() }

  _attachToMap() {
    this.map = this._hartaMap?.map
    if (!this.map) return
    this.map.addLayer(this._drawLayer)
    this.map.addLayer(this._snapZoneLayer)
    this.map.addLayer(this._axisLayer)
    this.map.addLayer(this._topoLayer)
    this.map.addLayer(this._editVertexLayer)  // cerculețele roșii la vertecși — pentru ambele moduri
    this.map.addLayer(this._editEdgeLabelsLayer)  // distanțele între vertecși, în interiorul poligonului
    this.map.addLayer(this._auditLayer)       // layer audit topologic global
    this._mouseMoveKey = this.map.on("pointermove", (evt) => this._onPointerMove(evt))
    this._moveEndKey   = this.map.on("moveend",     ()    => this._updateScale())
    this._updateScale()
    this._updateSaveAvailability()  // butoanele Salvează încep dezactivate

    // Dacă URL-ul indică editare (?edit_kind=parcela&edit_id=5), intrăm în mod editare
    if (this.editKindValue && this.editIdValue) {
      this._waitForFeatureAndEdit()
    }
  }

  _teardown() {
    if (this._mouseMoveKey) ol.Observable.unByKey(this._mouseMoveKey)
    if (this._moveEndKey)   ol.Observable.unByKey(this._moveEndKey)
    if (this._draw && this.map) this.map.removeInteraction(this._draw)
    if (this._postDrawModify && this.map) this.map.removeInteraction(this._postDrawModify)
    if (this._snap && this.map) this.map.removeInteraction(this._snap)
    if (this._drawLayer && this.map) this.map.removeLayer(this._drawLayer)
    if (this._topoLayer && this.map) this.map.removeLayer(this._topoLayer)
    if (this._editVertexLayer && this.map) this.map.removeLayer(this._editVertexLayer)
    if (this._editEdgeLabelsLayer && this.map) this.map.removeLayer(this._editEdgeLabelsLayer)
    this._draw = this._snap = this.map = this._hartaMap = null
  }

  // ── Public actions ───────────────────────────────────────────────────────

  togglePanel() {
    if (this.hasPanelTarget) this.panelTarget.classList.toggle("digi-panel--collapsed")
  }

  toggleSnap() {
    this._snapEnabled = !this._snapEnabled
    this.snapToggleTarget.classList.toggle("cad-status-toggle--on", this._snapEnabled)
    if (this._snap) this._snap.setActive(this._snapEnabled)
    this._setStatus(`SNAP ${this._snapEnabled ? "activ" : "oprit"}.`)
  }

  toggleOrtho() {
    this._orthoEnabled = !this._orthoEnabled
    this.orthoToggleTarget.classList.toggle("cad-status-toggle--on", this._orthoEnabled)
    this._setStatus(`ORTHO ${this._orthoEnabled ? "activ" : "oprit"}.`)
  }

  onSnapModeChange(evt) {
    const mode = evt.target.dataset.snapMode
    if (evt.target.checked) this._snapModes.add(mode)
    else this._snapModes.delete(mode)
    try {
      localStorage.setItem("harta:snapModes", JSON.stringify(Array.from(this._snapModes)))
    } catch (_) { /* no-op */ }
    if (this._draw || this._editing || this._postDrawModify) this._refreshSnap()
  }

  // Sincronizează `checked` pe toate checkbox-urile OSNAP cu starea curentă
  // a `_snapModes` (apelat la connect ca să reflecte valorile din localStorage).
  _syncSnapModeCheckboxes() {
    if (!this.hasSnapModesTarget) return
    this.snapModesTarget.querySelectorAll('[data-snap-mode]').forEach(box => {
      box.checked = this._snapModes.has(box.dataset.snapMode)
    })
  }

  onCmdKey(evt) {
    if (evt.key !== "Enter") return
    evt.preventDefault()
    const raw = this.cmdInputTarget.value.trim()
    if (!raw) return
    this.cmdInputTarget.value = ""

    // Înainte de parsing coordonate: încearcă comenzile text (AutoCAD-like).
    // Returnează `true` dacă raw e o comandă recunoscută → exit aici.
    if (this._dispatchCommand(raw)) return

    const isDistance   = /^-?\d+(\.\d+)?$/.test(raw)
    const isRelOrPolar = raw.startsWith("@")
    const isAbsolute   = !isDistance && !isRelOrPolar

    // Pornește digitizarea automat doar pentru coords absolute (au sens fără
    // punct anterior). Pentru distanță / relativ / polar, cere punct prim.
    if (!this._draw) {
      if (!isAbsolute) {
        this._cmdHint(`Eroare: ${raw} cere un punct anterior. Începe cu coords absolute (X,Y).`, true)
        return
      }
      this.startDrawing()
    }

    if (isDistance && this._verts.length === 0) {
      this._cmdHint(`Distanță fără punct anterior. Adaugă X,Y sau click pe hartă mai întâi.`, true)
      return
    }

    if (isDistance && !this._cursorStereo) {
      this._cmdHint(`Mișcă mouse-ul pe hartă pentru a stabili direcția înainte de a tasta lungimea.`, true)
      return
    }

    if (isDistance && this._cursorStereo && this._verts.length > 0) {
      const last = this._verts[this._verts.length - 1]
      const dx = this._cursorStereo.x - last.x
      const dy = this._cursorStereo.y - last.y
      if (Math.abs(dx) < 0.001 && Math.abs(dy) < 0.001) {
        this._cmdHint(`Mișcă mouse-ul departe de ultimul vertex pentru a stabili direcția, apoi reintroduce lungimea.`, true)
        return
      }
    }

    const pt = this._parseCmd(raw)
    if (!pt) {
      this._cmdHint(`Format invalid: ${raw}  (acceptat: X,Y · doar număr · @ΔX,ΔY · @len<deg; punctul zecimal cu .)`, true)
      return
    }

    const mapCoord = [pt.x, pt.y]  // direct în Stereo 70 (view e EPSG:3844)
    try {
      this._draw.appendCoordinates([mapCoord])
      const view = this.map.getView()
      if (!ol.extent.containsCoordinate(view.calculateExtent(this.map.getSize()), mapCoord)) {
        view.animate({ center: mapCoord, zoom: Math.max(view.getZoom() || 0, 6), duration: 250 })
      }
      this._cmdHint(`✓ Punct: X=${FMT(pt.x)}  Y=${FMT(pt.y)}`, false)
    } catch (e) {
      this._cmdHint(`Eroare appendCoordinates: ${e.message}`, true)
    }
  }

  _cmdHint(msg, isError) {
    if (!this.hasCmdHintTarget) return
    this.cmdHintTarget.textContent = msg
    this.cmdHintTarget.style.color = isError ? "#ef4444" : "#22c55e"
    clearTimeout(this._cmdHintTimer)
    this._cmdHintTimer = setTimeout(() => {
      this.cmdHintTarget.textContent = "Stereo70 (EPSG:3844)"
      this.cmdHintTarget.style.color = ""
    }, 3500)
  }

  // ── Comenzi text (AutoCAD-like) — invocate prin Enter pe command line ─────
  // Aliasuri: PAR/P/PARCELA, CL/CLA/CLADIRE, I/IN/INCHIDE, A/ESC/ANULEAZA,
  // U/UNDO, R/REDO, S/DEL/STERGE, M/MOD/MODIFICA, SV/SAVE/SALVEAZA,
  // Z/ZOOM, H/?/HELP.
  _dispatchCommand(raw) {
    const cmd = raw.toUpperCase()
    const aliases = {
      // Pornire desenare
      P: "PARCELA", PAR: "PARCELA", PARCELA: "PARCELA",
      CL: "CLADIRE", CLA: "CLADIRE", CLADIRE: "CLADIRE",
      D: "DRUM", DR: "DRUM", DRUM: "DRUM", LINIE: "DRUM",
      // Control geometrie
      I: "CLOSE", IN: "CLOSE", INCHIDE: "CLOSE",
      A: "CANCEL", ESC: "CANCEL", ANULEAZA: "CANCEL",
      U: "UNDO", UNDO: "UNDO",
      R: "REDO", REDO: "REDO",
      // Selecție + transformări
      S: "DELETE", DEL: "DELETE", STERGE: "DELETE",
      M: "EDIT", MOD: "EDIT", MODIFICA: "EDIT",
      MV: "MOVE", MUT: "MOVE", MUTA: "MOVE", MOVE: "MOVE",
      RO: "ROTATE", ROT: "ROTATE", ROTATE: "ROTATE", ROTESTE: "ROTATE",
      SV: "SAVE", SAVE: "SAVE", SALVEAZA: "SAVE",
      Z: "ZOOM", ZOOM: "ZOOM",
      H: "HELP", "?": "HELP", HELP: "HELP"
    }
    const action = aliases[cmd]
    if (!action) return false  // nu e comandă — lasă parserul de coords să încerce

    switch (action) {
      case "PARCELA":
        this.switchToParcel?.(); this.startDrawing()
        this._cmdHint("▶ Digitizare parcelă pornită.", false)
        break
      case "CLADIRE":
        this.switchToBuilding?.(); this.startDrawing()
        this._cmdHint("▶ Digitizare clădire pornită.", false)
        break
      case "DRUM":
        this.startLineDigitize()
        this._cmdHint("▶ Digitizare detaliu liniar (drum) pornită — setează lățimea în toolbar.", false)
        break
      case "CLOSE":
        if (this._draw && this._verts.length >= 3) {
          this.closePolygon()
          this._cmdHint("✓ Poligon închis. Continuă ajustare vertecși sau Salvează.", false)
        } else {
          this._cmdHint("Niciun poligon de închis sau < 3 vertecși.", true)
        }
        break
      case "CANCEL":
        if (this._postDrawTransform) { this._cancelTransform(); this._cmdHint("✕ Transformare anulată.", false) }
        else if (this._editing) { this.cancelEdit?.(); this._cmdHint("✕ Edit anulat.", false) }
        else if (this._draw || this._postDrawModify) { this.clearAll(); this._cmdHint("✕ Desenare anulată.", false) }
        else this._cmdHint("Nimic de anulat.", true)
        break
      case "UNDO":
        this._undo()
        break
      case "REDO":
        this._redo()
        break
      case "DELETE":
        if (this._selected) { this.deleteSelected(); this._cmdHint("🗑 Ștergere…", false) }
        else this._cmdHint("Niciun poligon selectat.", true)
        break
      case "EDIT":
        if (this._selected) { this.editSelected(); this._cmdHint("✎ Mod edit activ.", false) }
        else this._cmdHint("Niciun poligon selectat.", true)
        break
      case "MOVE":
        this._startMove()
        break
      case "ROTATE":
        this._startRotate()
        break
      case "SAVE":
        if (this._editing)            this.saveEdit?.()
        else if (this._entityType === "cladire") this.saveBuilding()
        else                          this.saveParcel()
        break
      case "ZOOM":
        if (this._selected?.feature) this._hartaMap?._zoomToFeature?.(this._selected.feature)
        else this._cmdHint("Selectează un poligon înainte de ZOOM.", true)
        break
      case "HELP":
        this._cmdHint("Comenzi: PAR | CL | DR (drum) | I (închide) | A (anulează) | U/R (undo/redo) | M | S | MV (mut) | RO (rot) | SV | Z", false)
        break
    }
    return true
  }

  // Acțiuni publice pentru butoanele toolbar Undo/Redo (proxy la _undo/_redo).
  undoAction() { this._undo(); this._updateUndoRedoState() }
  redoAction() { this._redo(); this._updateUndoRedoState() }

  // Undo unificat: în mod draw → elimină ultimul vertex; în post-draw modify
  // sau edit nu avem încă history geometrică completă, doar din vertex stack.
  _undo() {
    if (this._draw && this._verts.length > 0) {
      const last = this._verts[this._verts.length - 1]
      if (!this._redoStack) this._redoStack = []
      this._redoStack.push({ x: last.x, y: last.y })
      this.undoVertex()
      this._cmdHint(`↶ Undo vertex (${this._verts.length} rămași).`, false)
      return
    }
    this._cmdHint("Nimic de făcut UNDO.", true)
  }

  _redo() {
    if (this._draw && this._redoStack?.length) {
      const v = this._redoStack.pop()
      try {
        this._draw.appendCoordinates([[v.x, v.y]])
        this._cmdHint(`↷ Redo vertex (${this._verts.length} totale).`, false)
      } catch (e) {
        this._cmdHint(`Eroare REDO: ${e.message}`, true)
      }
      return
    }
    this._cmdHint("Nimic de făcut REDO.", true)
  }

  // Actualizează starea disabled pe butoanele Undo/Redo din toolbar.
  // Apelat la fiecare schimbare a stack-urilor (drawn vertices / redo stack).
  _updateUndoRedoState() {
    if (this.hasBtnUndoTarget) {
      this.btnUndoTarget.disabled = !(this._draw && this._verts.length > 0)
    }
    if (this.hasBtnRedoTarget) {
      this.btnRedoTarget.disabled = !(this._draw && this._redoStack?.length > 0)
    }
  }

  // ── Mută poligon (translație) ─────────────────────────────────────────────
  // Necesită selecție. Intră automat în edit mode (geometria se modifică, se
  // salvează prin SV/Salvează modificări via flow-ul existent). Drag pe orice
  // punct al poligonului = translație.
  // Mută poligon — flow AutoCAD-style:
  //   1. Click pe un vertex (punctul de bază)
  //   2. Mișcă cursor-ul → preview translație live; OSnap activ pe vertecșii vecinilor
  //   3. Click pe destinație → commit translație
  //   ESC / A = restaurare baseline. Save / Cancel = în panou.
  _startMove() {
    if (!this._ensureSelectedForTransform("MUT")) return
    if (this._postDrawTransform) this._cancelTransform()

    const feature = this._selected.feature
    const layer   = this._selected.layer
    if (!this._editing) {
      this.editKindValue = this._selected.kind
      this.editIdValue   = String(feature.get("id"))
      this._enterEditMode(feature, layer)
    }
    this._beginMoveByPoints([{ feature: this._editFeature, baseline: this._editFeature.getGeometry().clone(), kind: this.editKindValue }], "move")
  }

  // Helper unificat pentru mutare punct-la-punct (single sau bulk).
  // `items`: [{feature, baseline, kind}]. `mode`: "move" | "bulk-move".
  //
  // KEY INSIGHT: Modify interaction interceptează click pe vertex ca DRAG →
  // singleclick nu mai e tras. Soluție: dezactivăm Modify cât timp e activ
  // flow-ul click-click. Re-activăm după commit (pentru ajustări vertex post-mutare).
  //
  // KEY INSIGHT #2: `setGeometry()` instanță nouă → rupe listener-ul de pe
  // geometria veche. Folosim `setCoordinates()` pe geometria existentă →
  // change event firează → _extractVerts + _verifyTopology rulează.
  _beginMoveByPoints(items, mode) {
    // PREVIEW baseline = snapshot la START-ul ACESTEI mutări (current geometry).
    // ORIGINAL baseline (baseline + baselineCoords) e cel din _startBulkMove / _startMove
    // și NU se rescrie aici, ca să se păstreze pentru Cancel global la chain.
    items.forEach(it => {
      it.previewBaselineCoords = it.feature.getGeometry().getCoordinates()
      // Backwards-compat: pentru flow-uri fără chain (single move), baselineCoords
      // ar putea fi nesetat la intrare → folosim previewBaselineCoords ca fallback.
      if (!it.baselineCoords) it.baselineCoords = it.previewBaselineCoords
    })
    this._moveOp = { items, basePoint: null }
    this._postDrawTransform = mode
    this._cmdHint("MUT: click pe vertex pentru PUNCTUL DE BAZĂ (OSnap activ).", false)

    // Dezactivăm Modify ca să nu intercepteze click-urile pe vertecși.
    if (this._modify) this._modify.setActive(false)

    // Pentru single-move, randăm vertecșii poligoanelor din viewport ca ținte
    // VIZUALE de destinație (cerculețe portocalii). Pentru bulk-move, deja
    // făcute în _renderBulkVertices.
    if (mode === "move" && this._editFeature) {
      this._renderDestinationVertices(new Set([this._editFeature]))
    }

    // Refresh Snap → include și vertecșii randați la _renderBulkVertices în
    // _editVertexSource. Sursa default vine din parcele/cladiri/cgxml.
    this._refreshSnap()

    this._moveClickKey = this.map.on("singleclick", (evt) => {
      if (!this._moveOp.basePoint) {
        // Click 1 — punctul de bază: căutăm MANUAL cel mai apropiat vertex al
        // poligoanelor în mișcare (OL Snap le exclude pentru destinație, deci
        // nu poate snap-ui la ele aici). Toleranță 30px.
        const clickPx = this.map.getPixelFromCoordinate(evt.coordinate)
        const baseVert = this._findNearestMovingVertex(evt.coordinate, clickPx, 30)
        const basePt = baseVert || [evt.coordinate[0], evt.coordinate[1]]
        this._moveOp.basePoint = basePt
        this._renderMoveMarker(basePt, "base")
        this._cmdHint("MUT: click pe DESTINAȚIE (OSnap activ pe vertecșii vecinilor).", false)

        // Preview live: pe pointermove translatează cu offsetul curent + arată
        // un indicator vizual la destinația snap-uită (vertex vecin în limită).
        this._moveMoveKey = this.map.on("pointermove", (mEvt) => {
          const dx = mEvt.coordinate[0] - this._moveOp.basePoint[0]
          const dy = mEvt.coordinate[1] - this._moveOp.basePoint[1]
          this._applyMoveDelta(dx, dy)
          // Indicator de snap: detect manual cel mai apropiat vertex de
          // destinație (poligoanele aflate în mișcare sunt deja excluse).
          const px = this.map.getPixelFromCoordinate(mEvt.coordinate)
          const snapTo = this._findNearestSnapTarget(mEvt.coordinate, px, this.snapToleranceValue || 14)
          this._renderSnapHover(snapTo)
        })
        return
      }
      // Click 2: commit la destinația snap-uită (OL Snap a modificat deja evt.coordinate)
      const dx = evt.coordinate[0] - this._moveOp.basePoint[0]
      const dy = evt.coordinate[1] - this._moveOp.basePoint[1]
      this._applyMoveDelta(dx, dy)

      this._removeMoveMarkers()
      this._removeSnapHover()
      if (this._moveMoveKey)  { ol.Observable.unByKey(this._moveMoveKey);  this._moveMoveKey = null }
      if (this._moveClickKey) { ol.Observable.unByKey(this._moveClickKey); this._moveClickKey = null }
      this._hartaMap?._refreshMultiSelectOverlay?.()

      // Re-extragem _verts din geometria mutată + re-validăm topologia.
      // Pentru single move, geometria primarului = _editFeature.
      if (mode === "move" && this._editFeature) {
        this._extractVerts(this._editFeature.getGeometry())
        this._renderEditVertices()
        this._calcArea()
        this._verifyTopology()
      }

      // Re-activăm Modify (single move) ca user-ul să poată ajusta vertecși după.
      if (mode === "move" && this._modify) this._modify.setActive(true)

      // Panou save: bulk → controlul comun bulk; single → panoul existent.
      if (mode === "bulk-move") {
        this._bulkOp = { type: "move", items: this._moveOp.items }
        // Transferăm items spre _bulkOp, ștergem _moveOp ca _buildSnapFeatures
        // să nu mai excludă items (excluderea e gestionată acum de _bulkOp +
        // snapIncludeBulkItems din _enableBulkVertexEditing).
        this._moveOp = null
        // Activăm editarea de vertecși pentru fiecare poligon din grup.
        // User-ul poate corecta erorile topologice prin drag pe vertecși.
        this._enableBulkVertexEditing(this._bulkOp.items)
        this._injectBulkControls("Mutare bloc", this._bulkOp.items.length, [
          "Translație aplicată din punctul de bază la destinație.",
          "<b>Drag pe orice vertex</b> pentru ajustare topologie.",
          "Save validează topologia înainte de persistare."
        ])
      } else {
        this._injectMoveControls()
      }
      this._cmdHint("✓ Mutare aplicată. Drag vertex pentru ajustări sau Save.", false)
    })
  }

  // Caută cel mai apropiat vertex de `coord` printre TOATE poligoanele din
  // viewport, EXCLUZÂND cele aflate în mișcare. Folosit pentru indicatorul
  // vizual de snap la destinație.
  _findNearestSnapTarget(coord, clickPx, pxTolerance) {
    if (!this._hartaMap || !this.map) return null
    const exclude = new Set()
    if (this._moveOp?.items) this._moveOp.items.forEach(it => exclude.add(it.feature))
    if (this._bulkOp?.items) this._bulkOp.items.forEach(it => exclude.add(it.feature))
    const view   = this.map.getView()
    const extent = view.calculateExtent(this.map.getSize())
    const layers = [
      this._hartaMap.parcelLayer,
      this._hartaMap.cladiriLayer,
      this._hartaMap.cgxmlLayer
    ].filter(Boolean)
    let best = null
    let bestPxDist = Infinity
    layers.forEach(layer => {
      const src = layer.getSource()
      if (!src) return
      src.forEachFeatureInExtent(extent, (f) => {
        if (exclude.has(f)) return
        const geom = f.getGeometry()
        if (!geom) return
        const t = geom.getType()
        const rings = t === "Polygon" ? geom.getCoordinates()
                    : t === "MultiPolygon" ? geom.getCoordinates().flat()
                    : []
        rings.forEach(ring => {
          const verts = ring.length > 1 ? ring.slice(0, -1) : ring
          verts.forEach(c => {
            const px = this.map.getPixelFromCoordinate(c)
            const d  = Math.hypot(px[0] - clickPx[0], px[1] - clickPx[1])
            if (d < bestPxDist && d <= pxTolerance) {
              bestPxDist = d
              best = [c[0], c[1]]
            }
          })
        })
      })
    })
    return best
  }

  // Marker vizibil pentru snap-ul la destinație (cerculeț cyan mare).
  // Marcheaza prin flag `snapHover` pentru cleanup uniform.
  _renderSnapHover(coord) {
    if (!this._editVertexSource) return
    this._removeSnapHover()
    if (!coord) return
    const f = new ol.Feature(new ol.geom.Point(coord))
    f.set("snapHover", true)
    this._editVertexSource.addFeature(f)
  }

  _removeSnapHover() {
    if (!this._editVertexSource) return
    this._editVertexSource.getFeatures()
      .filter(f => f.get("snapHover"))
      .forEach(f => this._editVertexSource.removeFeature(f))
  }

  // Activează Modify pe TOATE features-urile din selecția bulk. User-ul poate
  // trage orice vertex pentru a corecta erori topologice (overlap-uri minore,
  // goluri) post-mutare/post-rotație. Toate schimbările sunt incluse în save.
  _enableBulkVertexEditing(items) {
    if (!this.map || !items?.length) return
    if (this._bulkModify) {
      this.map.removeInteraction(this._bulkModify)
      this._bulkModify = null
    }
    const features = items.map(it => it.feature)
    const coll = new ol.Collection(features)
    this._bulkModify = new ol.interaction.Modify({
      features:       coll,
      pixelTolerance: 12,
      deleteCondition: (e) => {
        const oe = e.originalEvent
        return e.type === "singleclick" && (oe?.shiftKey || oe?.altKey)
      }
    })
    this.map.addInteraction(this._bulkModify)
    this._bulkModify.on("modifyend", () => {
      this._hartaMap?._refreshMultiSelectOverlay?.()
      this._refreshBulkVertexCirles(items)
    })
    // IMPORTANT: după commit (move sau rotate), vertecșii din `_editVertexSource`
    // au RĂMAS la pozițiile de DINAINTE de operațiune (au fost randați la start).
    // Re-randăm imediat ca să reflecte pozițiile FINALE (post-mutare/rotație).
    this._refreshBulkVertexCirles(items)
    // Snap include items pentru editare vertex-on-vertex în cadrul grupului.
    this._snapIncludeBulkItems = true
    this._refreshSnap()
  }

  // Re-randează cerculețele de vertex pentru items după ce user-ul a făcut drag.
  _refreshBulkVertexCirles(items) {
    if (!this._editVertexSource) return
    // Păstrăm visualNeighbor (vertecșii destinației) — nu se schimbă.
    const keep = this._editVertexSource.getFeatures()
      .filter(f => f.get("visualNeighbor") || f.get("snapHover"))
    this._editVertexSource.clear()
    keep.forEach(f => this._editVertexSource.addFeature(f))
    items.forEach(it => {
      this._addAllVertexesAsPoints(it.feature, this._editVertexSource, false)
    })
  }

  // Caută vertex-ul cel mai apropiat de `coord` printre poligoanele din
  // `_moveOp.items`. Toleranță în pixeli (snap rate identic cu OL Snap).
  // Returnează [x, y] în EPSG:3844 sau null dacă nu există vertex în limită.
  _findNearestMovingVertex(coord, clickPx, pxTolerance) {
    if (!this._moveOp?.items) return null
    let best = null
    let bestPxDist = Infinity
    this._moveOp.items.forEach(it => {
      // Folosim previewBaselineCoords = snapshot la start-ul mutării curente
      // (la chain, NU baselineCoords care e original pre-chain).
      const src = it.previewBaselineCoords || it.baselineCoords
      const t = it.feature.getGeometry().getType()
      const rings = t === "Polygon" ? src
                  : t === "MultiPolygon" ? src.flat()
                  : []
      rings.forEach(ring => {
        const verts = ring.length > 1 ? ring.slice(0, -1) : ring
        verts.forEach(c => {
          const px = this.map.getPixelFromCoordinate(c)
          const d  = Math.hypot(px[0] - clickPx[0], px[1] - clickPx[1])
          if (d < bestPxDist && d <= pxTolerance) {
            bestPxDist = d
            best = [c[0], c[1]]
          }
        })
      })
    })
    return best
  }

  // Aplică translația dx/dy pe toate features-urile din _moveOp folosind
  // setCoordinates (păstrează instanța geometriei → change event firează).
  // Translatează din previewBaselineCoords (snapshot la start-ul mutării), NU
  // din baselineCoords (= original pre-chain).
  _applyMoveDelta(dx, dy) {
    this._moveOp.items.forEach(it => {
      const geom = it.feature.getGeometry()
      const t = geom.getType()
      const src = it.previewBaselineCoords || it.baselineCoords
      let translated
      if (t === "Polygon") {
        translated = src.map(ring => ring.map(([x, y]) => [x + dx, y + dy]))
      } else if (t === "MultiPolygon") {
        translated = src.map(poly => poly.map(ring => ring.map(([x, y]) => [x + dx, y + dy])))
      } else {
        return
      }
      geom.setCoordinates(translated)
    })
    this._hartaMap?._refreshMultiSelectOverlay?.()
  }

  _renderMoveMarker(coord, kind) {
    if (!this._editVertexSource) return
    const f = new ol.Feature(new ol.geom.Point(coord))
    f.set("moveMarker", kind)  // "base" sau "dest"
    this._editVertexSource.addFeature(f)
  }

  _removeMoveMarkers() {
    if (!this._editVertexSource) return
    this._editVertexSource.getFeatures()
      .filter(f => f.get("moveMarker"))
      .forEach(f => this._editVertexSource.removeFeature(f))
  }

  // Buton dedicat „Salvează mutarea" + „Anulează" în sidebar — injectat la
  // începutul panel-body pentru vizibilitate maximă în timpul operațiunii.
  _injectMoveControls() {
    if (!this.hasPanelBodyTarget) return
    this.element.querySelector(".digi-move-controls")?.remove()
    const div = document.createElement("section")
    // Reutilizăm `.digi-edit-panel` ca să aibă același design ca panoul de
    // edit (header gălbui, border-left warn, padding identic).
    div.className = "digi-section digi-edit-panel digi-move-controls"
    div.innerHTML = `
      <div class="digi-edit-header">Mutare poligon (translație)</div>
      <ul class="digi-parcela-hint" style="margin:6px 0;padding-left:18px;line-height:1.6">
        <li><b>Drag</b> pe geometrie → translație cu OSnap activ pe vertecșii vecinilor</li>
      </ul>
      <button type="button" class="btn btn-primary btn-sm digi-ctx-btn"
              data-action="click->digitizare#saveMove">${this._iconSave()} Salvează mutarea</button>
      <button type="button" class="btn btn-secondary btn-sm digi-ctx-btn"
              data-action="click->digitizare#cancelMove">${this._iconCancel()} Anulează mutarea</button>
    `
    this.panelBodyTarget.insertBefore(div, this.panelBodyTarget.firstChild)
  }

  // Iconuri SVG inline pentru butoanele de context (același set ca toolbar).
  // currentColor = culoarea butonului din clasă (btn-primary alb, btn-secondary închis).
  _iconSave()   { return `<svg class="digi-ctx-ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z"/><polyline points="17 21 17 13 7 13 7 21"/><polyline points="7 3 7 8 15 8"/></svg>` }
  _iconCancel() { return `<svg class="digi-ctx-ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="m15 9-6 6"/><path d="m9 9 6 6"/></svg>` }
  _iconExternal() { return `<svg class="digi-ctx-ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><polyline points="15 3 21 3 21 9"/><line x1="10" x2="21" y1="14" y2="3"/></svg>` }

  _removeMoveControls() {
    this.element.querySelector(".digi-move-controls")?.remove()
  }

  // Acțiuni publice pentru butoanele din panoul Mutare.
  saveMove() {
    this._removeMoveControls()
    this.saveEdit?.()
  }

  cancelMove() {
    this._cancelTransform()
    this._removeMoveControls()
    this.cancelEdit?.()
  }

  // ── Rotește poligon ───────────────────────────────────────────────────────
  // Flow:
  //   1. User dă click pe Rotește → intră edit + așteaptă click pe vertex pivot.
  //   2. Click 1 = pivot. Cursor-ul devine referință pentru unghiul de pornire.
  //   3. Pointermove = preview rotație live în jurul pivot-ului.
  //   4. Click 2 = commit (păstrează geometria rotită). ESC / A = restaurare.
  // Vertex pivot vizualizat distinct (cerc mare portocaliu).
  _startRotate() {
    if (!this._ensureSelectedForTransform("ROT")) return
    if (this._postDrawTransform) this._cancelTransform()

    const feature = this._selected.feature
    if (!this._editing) {
      this.editKindValue = this._selected.kind
      this.editIdValue   = String(feature.get("id"))
      this._enterEditMode(feature, this._selected.layer)
    }

    this._rotateBaseline      = this._editFeature.getGeometry().clone()
    this._rotateBaselineCoords = this._rotateBaseline.getCoordinates()
    this._rotatePivot         = null     // se setează la primul click pe vertex
    this._rotateStartAngle    = null
    this._postDrawTransform   = "rotate"

    // Dezactivăm Modify cât timp e activ flow-ul click-click (altfel click pe
    // vertex pornește drag și singleclick nu mai e tras).
    if (this._modify) this._modify.setActive(false)
    this._refreshSnap()

    this._cmdHint("ROT: click pe un vertex pentru a-l alege ca pivot de rotație.", false)

    this._rotateClickKey = this.map.on("singleclick", (evt) => {
      if (!this._rotatePivot) {
        // Click 1 — alege pivotul: vertex-ul cel mai apropiat de click
        // (snap-ul OL ar fi trebuit deja să prindă coordonata pe vertex).
        const click = evt.coordinate
        let bestDist = Infinity
        let bestVert = null
        for (const v of this._verts || []) {
          const d = Math.hypot(v.x - click[0], v.y - click[1])
          if (d < bestDist) { bestDist = d; bestVert = [v.x, v.y] }
        }
        if (!bestVert) {
          this._cmdHint("ROT: niciun vertex disponibil.", true)
          return
        }
        this._rotatePivot = bestVert
        this._renderRotatePivotMarker(bestVert)
        this._cmdHint("ROT: mișcă cursor-ul pentru rotație · click confirmă · A anulează.", false)

        // Tracking rotație live — folosim setCoordinates ca să nu spargem listener-ul.
        this._rotateMoveKey = this.map.on("pointermove", (mEvt) => {
          const cur = mEvt.coordinate
          const a   = Math.atan2(cur[1] - bestVert[1], cur[0] - bestVert[0])
          if (this._rotateStartAngle === null) {
            this._rotateStartAngle = a
            return
          }
          const delta = a - this._rotateStartAngle
          const rotated = this._rotateBaseline.clone()
          rotated.rotate(delta, bestVert)
          this._editFeature.getGeometry().setCoordinates(rotated.getCoordinates())
        })
        return
      }
      // Click 2 — commit. (Primul tracking pointermove a stabilit unghiul de start.)
      if (this._rotateStartAngle === null) return
      this._endRotate()
      // Re-extragem verts + re-validăm topologia pe geometria rotită.
      this._extractVerts(this._editFeature.getGeometry())
      this._renderEditVertices()
      this._calcArea()
      this._verifyTopology()
      // Re-activăm Modify ca user-ul să poată ajusta vertecși după rotație.
      if (this._modify) this._modify.setActive(true)
      this._cmdHint("✓ Rotație aplicată. SV salvează modificările.", false)
    })
  }

  _renderRotatePivotMarker(coord) {
    if (!this._editVertexSource) return
    const f = new ol.Feature(new ol.geom.Point(coord))
    f.set("rotatePivot", true)
    this._editVertexSource.addFeature(f)
  }

  _removeRotatePivotMarker() {
    if (!this._editVertexSource) return
    this._editVertexSource.getFeatures()
      .filter(f => f.get("rotatePivot"))
      .forEach(f => this._editVertexSource.removeFeature(f))
  }

  _endRotate() {
    if (this._rotateMoveKey)  { ol.Observable.unByKey(this._rotateMoveKey);  this._rotateMoveKey = null }
    if (this._rotateClickKey) { ol.Observable.unByKey(this._rotateClickKey); this._rotateClickKey = null }
    this._removeRotatePivotMarker()
    this._rotateBaseline   = null
    this._rotatePivot      = null
    this._rotateStartAngle = null
    this._postDrawTransform = null
  }

  // Anulează orice transformare în curs (apelat din _cancelTransform sau
  // command „A"/cancelEdit). Restaurează geometria originală.
  _cancelTransform() {
    const restoreBaseline = (it) => {
      // Folosim setCoordinates ca să păstrăm instanța geometriei (listener change valid).
      if (it.baselineCoords) {
        it.feature.getGeometry().setCoordinates(it.baselineCoords)
      } else if (it.baseline) {
        it.feature.setGeometry(it.baseline)
      }
    }
    if (this._postDrawTransform === "move") {
      // Click-click flow: restaurează baseline pe single feature.
      if (this._moveOp?.items?.length) {
        this._moveOp.items.forEach(restoreBaseline)
      }
      if (this._moveMoveKey)  { ol.Observable.unByKey(this._moveMoveKey);  this._moveMoveKey = null }
      if (this._moveClickKey) { ol.Observable.unByKey(this._moveClickKey); this._moveClickKey = null }
      this._removeMoveMarkers()
      this._removeMoveControls()
      // Re-activăm Modify dacă a fost dezactivat la start move.
      if (this._modify) this._modify.setActive(true)
      this._moveOp = null
    }
    if (this._postDrawTransform === "rotate") {
      if (this._rotateBaseline && this._editFeature) {
        // Restaurăm cu setCoordinates → păstrăm instanța geometriei (listener change valid).
        this._editFeature.getGeometry().setCoordinates(this._rotateBaseline.getCoordinates())
      }
      if (this._modify) this._modify.setActive(true)
      this._endRotate()
    }
    if (this._postDrawTransform === "bulk-move" || this._postDrawTransform === "bulk-rotate") {
      // bulk-move folosește același _moveOp + _bulkOp; restaurează ambele.
      if (this._moveOp?.items?.length) {
        this._moveOp.items.forEach(restoreBaseline)
      }
      if (this._moveMoveKey)  { ol.Observable.unByKey(this._moveMoveKey);  this._moveMoveKey = null }
      if (this._moveClickKey) { ol.Observable.unByKey(this._moveClickKey); this._moveClickKey = null }
      this._removeMoveMarkers()
      this._moveOp = null
      this._cancelBulk()
    }
    this._postDrawTransform = null
  }

  _ensureSelectedForTransform(label) {
    if (!this._selected) {
      this._cmdHint(`${label}: niciun poligon selectat.`, true)
      return false
    }
    return true
  }

  startDrawing() {
    if (!this.map) return
    this.clearAll()
    // Curățare DEFENSIVĂ pentru interacțiunile reziduale din alte module:
    // poly-select lasso, multi-select dragbox, export draw — orice ar putea
    // intercepta primul click pe hartă în loc să-l lase la noul Draw.
    this._hartaMap?._endPolygonSelect?.()
    this._hartaMap?.disableMultiSelect?.()
    if (this._exportDraw && this.map) {
      this.map.removeInteraction(this._exportDraw); this._exportDraw = null
    }

    this._hartaMap?.setDigitizing(true)

    this._draw = new ol.interaction.Draw({
      source: this._drawSource,
      type:   "Polygon",
      style:  this._drawStyle.bind(this),
      geometryFunction: this._buildGeometryFunction()
    })
    this.map.addInteraction(this._draw)

    this._refreshSnap()

    this._draw.on("drawstart", (evt) => this._onDrawStart(evt))
    this._draw.on("drawend",   (evt) => this._onDrawEnd(evt))

    this.btnStartTarget.classList.add("btn-active")
    this.btnCloseTarget.disabled = false
    this.btnUndoTarget.disabled  = true   // disabled până la primul vertex
    if (this.hasBtnRedoTarget) this.btnRedoTarget.disabled = true
    this._redoStack = []                  // resetăm stack-ul de redo la pornire desen
    this._updateToolbarVisibility?.()
    const hint = this._metricSnap?.enabled
      ? `METRIC (${this._metricSnap.meters.toFixed(1)} m): desenezi liber. La SAVE, vertecșii în rază se vor potrivi automat pe vertecșii vecinilor.`
      : "Clic pe hartă pentru primul vertex. Dublu-clic pentru închidere. F8=ORTHO."
    this._setStatus(hint)
  }

  // ── Digitizare detaliu liniar (drum) — ax + lățime → poligon ──────────
  // User-ul desenează LineString-ul axei. La drawend, serverul calculează
  // ST_Buffer (lățime/2 stânga + dreapta, capete flat) și clip la vecinii
  // care intersectează. Rezultatul: un Polygon care intră în flow-ul normal
  // de post-draw (Modify + form parcelă + save_batch).
  startLineDigitize() {
    if (!this.map) return
    this.clearAll()
    this._hartaMap?._endPolygonSelect?.()
    this._hartaMap?.disableMultiSelect?.()
    if (this._exportDraw && this.map) { this.map.removeInteraction(this._exportDraw); this._exportDraw = null }
    this._hartaMap?.setDigitizing(true)
    this.switchToParcel?.()

    // Default params (suprascriși via popup); persistăm valorile între digitizări.
    if (!this._drumLastParams) this._drumLastParams = { widthM: 6, snapDist: 5 }
    // Afișează popup-ul ÎNAINTE de desenare ca utilizatorul să poată seta
    // lățimea și pragul de alipire înainte să dea click pe hartă.
    this._showDrumParamsPopup()

    this._lineDraw = new ol.interaction.Draw({
      source: this._drawSource,
      type:   "LineString",
      style:  this._drawStyle.bind(this)
    })
    this.map.addInteraction(this._lineDraw)
    this._refreshSnap()

    this._lineDraw.on("drawstart", (evt) => {
      this._currentFeature = evt.feature
    })
    this._lineDraw.on("drawend", (evt) => this._onLineDrawEnd(evt))

    if (this.hasBtnLineDigitizeTarget) this.btnLineDigitizeTarget.classList.add("btn-active")
    if (this.hasBtnCloseTarget) this.btnCloseTarget.disabled = false
    this._updateToolbarVisibility?.()
    this._setStatus(`Detaliu liniar (drum) ${this._drumLastParams.widthM} m: click pe hartă pentru axa. Parametri în popup.`)
  }

  async _onLineDrawEnd(evt) {
    if (this._lineDraw && this.map) {
      this.map.removeInteraction(this._lineDraw)
      this._lineDraw = null
    }
    if (this.hasBtnLineDigitizeTarget) this.btnLineDigitizeTarget.classList.remove("btn-active")

    const feature = evt.feature
    const lineGeom = feature.getGeometry()
    const coords = lineGeom.getCoordinates() || []
    if (coords.length < 2) {
      this._setStatus("Linie cu mai puțini de 2 vertecși — anulat.", "warn")
      try { this._drawSource.removeFeature(feature) } catch (e) {}
      this._hartaMap?.setDigitizing(false)
      return
    }
    // Parametrii vin din popup (state-ul `_drumLastParams`, sau default 6/5).
    const widthM   = this._drumLastParams?.widthM   ?? 6
    const snapDist = this._drumLastParams?.snapDist ?? 5
    if (widthM <= 0 || widthM > 50) {
      this._setStatus(`Lățime invalidă (${widthM}) — folosește 0.5–50 m.`, "warn")
      try { this._drawSource.removeFeature(feature) } catch (e) {}
      this._hartaMap?.setDigitizing(false)
      return
    }
    const lineWkt = "LINESTRING(" + coords.map(([x, y]) => `${x.toFixed(6)} ${y.toFixed(6)}`).join(", ") + ")"

    // Mută axa în _axisSource (separat de _drawSource ca să o putem edita).
    try { this._drawSource.removeFeature(feature) } catch (e) {}
    this._axisSource.clear()
    this._axisFeature = feature
    this._axisSource.addFeature(feature)

    // Modify pe AXĂ — utilizatorul editează vertecșii axei, NU marginile benzii.
    // La modifyend, debounced re-recompute drum din axa actualizată.
    if (this._axisModify) this.map.removeInteraction(this._axisModify)
    this._axisModify = new ol.interaction.Modify({
      features: new ol.Collection([feature]),
      pixelTolerance: 12
    })
    this.map.addInteraction(this._axisModify)
    this._axisModify.on("modifyend", () => {
      clearTimeout(this._axisDebounce)
      this._axisDebounce = setTimeout(() => this._regenFromAxis(), 300)
    })

    this._drumOriginalLineWkt = lineWkt
    this._setStatus(`Calculare buffer ${widthM}m + alipire vecini (${snapDist}m)…`)
    try {
      const res = await fetch(this.bufferDrumUrlValue, {
        method:  "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf(), "Accept": "application/json" },
        body:    JSON.stringify({ line_wkt: lineWkt, width_m: widthM, snap_dist_m: snapDist })
      })
      const data = await res.json()
      if (!data.ok) {
        this._setStatus(`Eroare buffer: ${data.error || "necunoscută"}.`, "warn")
        this._hartaMap?.setDigitizing(false)
        return
      }
      console.log("[buffer_drum]", {
        affected: data.affected_neighbors?.length || 0,
        diagnostic: data.diagnostic
      })
      const fmt = new ol.format.GeoJSON()
      this._drumCachedNeighbors = data.affected_neighbors || []
      this._drumAffectedNeighbors = null
      this._drumNeighborsApplied = false

      // Afișează zona de prag alipire (inel în jurul drumului).
      this._renderSnapZone(data.snap_zone_geojson)

      // Banda drumului → display-only în _drawSource (NU Modify pe ea!).
      // Vertecșii editabili sunt pe AXĂ (în _axisSource). La modificare axă
      // → re-calcul automat al benzii prin _regenFromAxis.
      this._drawSource.getFeatures()
        .filter(f => f !== this._axisFeature)
        .forEach(f => this._drawSource.removeFeature(f))
      const polyFeat = fmt.readFeature(data.geojson, {
        dataProjection: "EPSG:3844", featureProjection: "EPSG:3844"
      })
      this._drawSource.addFeature(polyFeat)
      this._currentFeature = polyFeat
      this._drumMode = true
      this._extractVerts(polyFeat.getGeometry())
      // În mod drum, vertecșii editabili sunt pe AXĂ (în _axisLayer).
      // Curățăm cerculețele pe banda drumului — utilizatorul NU le poate edita.
      if (this._editVertexSource) this._editVertexSource.clear()
      this._calcArea?.()

      const nCount = this._drumCachedNeighbors.length
      this._setStatus(`Drum: ${data.area_mp.toFixed(2)} m² · ${nCount} vecini detectați. Editează vertecșii AXEI (linia portocalie) sau aplică pe vecini.`, "ok")
      this._showDrumParamsPopup()
    } catch (e) {
      this._setStatus(`Eroare rețea: ${e.message}`, "warn")
      this._hartaMap?.setDigitizing(false)
    }
  }

  // Popup de parametri drum (lățime + prag alipire) cu live-update.
  // Apare după buffer_drum cu succes; utilizatorul poate modifica parametrii
  // → buffer_drum se re-rulează automat (debounced) și vecinii se re-aplică.
  _showDrumParamsPopup() {
    if (this._drumPopup) { try { this._drumPopup.remove() } catch (e) {} }
    const panel = document.createElement("div")
    panel.className = "digi-drum-params-popup"
    const drawn   = !!this._drumOriginalLineWkt
    const applied = !!this._drumNeighborsApplied
    const nCached = this._drumCachedNeighbors?.length || 0
    const nApplied = this._drumAffectedNeighbors?.length || 0

    // Etape:
    //   1) drawn=false       → așteaptă desenare axă (doar Anulează)
    //   2) drawn=true, applied=false → drum vizibil, Aplică pe N vecini disponibil
    //   3) applied=true      → vecinii aplicați, Salvează disponibil
    let actions = ""
    let hint = ""
    if (!drawn) {
      hint = "Desenează axul pe hartă (click pe fiecare vertex, dublu-click la final)."
      actions = `
        <button type="button" class="digi-drum-params-cancel">${this._iconCancel()} Anulează</button>
      `
    } else if (!applied) {
      hint = `Drum trasat (${nCached} vecini detectați). Editează vertecșii drumului dacă e cazul, apoi <b>Aplică pe vecini</b>.`
      actions = `
        <button type="button" class="digi-drum-params-apply" ${nCached === 0 ? "disabled" : ""}>
          ✓ Aplică pe ${nCached} vecin(i)
        </button>
        <button type="button" class="digi-drum-params-cancel">${this._iconCancel()} Anulează</button>
      `
    } else {
      hint = `Vecini aplicați (${nApplied}). Ajustează vertecși partajati dacă vrei, apoi <b>Salvează</b>.`
      actions = `
        <button type="button" class="digi-drum-params-save">
          ${this._iconSave()} Salvează drum + ${nApplied} vecin(i)
        </button>
        <button type="button" class="digi-drum-params-cancel">${this._iconCancel()} Anulează</button>
      `
    }

    panel.innerHTML = `
      <div class="digi-drum-params-header">⚙ Drum — parametri</div>
      <label class="digi-drum-params-row">
        <span>Lățime</span>
        <input type="number" class="digi-drum-params-width"
               value="${this._drumLastParams.widthM}" min="0.5" max="50" step="0.5">
        <span>m</span>
      </label>
      <label class="digi-drum-params-row">
        <span>Prag alipire</span>
        <input type="number" class="digi-drum-params-snap"
               value="${this._drumLastParams.snapDist}" min="0.5" max="20" step="0.5">
        <span>m</span>
      </label>
      <div class="digi-drum-params-actions">${actions}</div>
      <div class="digi-drum-params-hint">${hint}</div>
    `
    this.element.appendChild(panel)
    this._drumPopup = panel
    const widthInput = panel.querySelector(".digi-drum-params-width")
    const snapInput  = panel.querySelector(".digi-drum-params-snap")
    const onChange = () => {
      const w  = Math.max(0.5, Math.min(50,  parseFloat(widthInput.value) || 6))
      const s  = Math.max(0.5, Math.min(20,  parseFloat(snapInput.value)  || 5))
      this._drumLastParams = { widthM: w, snapDist: s }
      if (!this._drumOriginalLineWkt) return
      clearTimeout(this._drumParamsDebounce)
      this._drumParamsDebounce = setTimeout(() => this._recomputeDrum(), 350)
    }
    widthInput.addEventListener("input", onChange)
    snapInput.addEventListener("input", onChange)
    const applyBtn = panel.querySelector(".digi-drum-params-apply")
    if (applyBtn) applyBtn.addEventListener("click", () => this._applyDrumNeighbors())
    const saveBtn = panel.querySelector(".digi-drum-params-save")
    if (saveBtn) saveBtn.addEventListener("click", () => { this._closeDrumPopup(); this._saveDrum() })
    panel.querySelector(".digi-drum-params-cancel").addEventListener("click", () => {
      this._closeDrumPopup()
      this.clearAll()
      this._setStatus("Digitizare drum anulată.", "info")
    })
  }

  // Aplică pe vecini cache-uitele transformări (snap/translate calculate de server).
  // Apelat când utilizatorul confirmă traseul drumului via popup.
  _applyDrumNeighbors() {
    if (!this._drumCachedNeighbors?.length) {
      this._setStatus("Niciun vecin de aplicat.", "warn")
      return
    }
    const fmt = new ol.format.GeoJSON()
    const findFeature = (kind, id) => {
      const wantedId = Number(id)
      const candidateLayers = kind === "cladire"
        ? [this._hartaMap?.cladiriLayer, this._hartaMap?.cgxmlLayer]
        : [this._hartaMap?.parcelLayer,  this._hartaMap?.cgxmlLayer]
      for (const layer of candidateLayers) {
        const src = layer?.getSource()
        if (!src) continue
        const feat = src.getFeatures().find(f => {
          if (Number(f.get("id")) !== wantedId) return false
          const etype = f.get("entity_type")
          if (etype === "land"     && kind === "parcela") return true
          if (etype === "building" && kind === "cladire") return true
          if (!etype) return true
          return false
        })
        if (feat) return { feat, src }
      }
      return null
    }
    this._drumAffectedNeighbors = []
    this._drumCachedNeighbors.forEach(n => {
      const found = findFeature(n.kind, n.id)
      if (!found) return
      const { feat, src } = found
      const originalCoords = feat.getGeometry().getCoordinates()
      const originalType   = feat.getGeometry().getType()
      if (n.delete) {
        try { src.removeFeature(feat) } catch (e) {}
        this._drumAffectedNeighbors.push({
          kind: n.kind, id: n.id, feature: feat, sourceLayer: src,
          originalCoords, originalType, deleteFlag: true
        })
        return
      }
      const newGeom = fmt.readGeometry(n.new_geojson, {
        dataProjection: "EPSG:3844", featureProjection: "EPSG:3844"
      })
      feat.setGeometry(newGeom)
      this._drumAffectedNeighbors.push({
        kind: n.kind, id: n.id, feature: feat, sourceLayer: src,
        originalCoords, originalType, deleteFlag: false
      })
    })

    // Extinde _postDrawModify ca user-ul să poată ajusta vertecșii partajati.
    const modifiable = this._drumAffectedNeighbors.filter(n => !n.deleteFlag)
    if (modifiable.length > 0 && this._postDrawModify && this.map && this._currentFeature) {
      this.map.removeInteraction(this._postDrawModify)
      const allFeatures = [this._currentFeature, ...modifiable.map(n => n.feature)]
      this._postDrawModify = new ol.interaction.Modify({
        features:       new ol.Collection(allFeatures),
        pixelTolerance: 12,
        deleteCondition: (e) => {
          const oe = e.originalEvent
          return e.type === "singleclick" && (oe?.shiftKey || oe?.altKey)
        }
      })
      this.map.addInteraction(this._postDrawModify)
      this._refreshSnap()
    }

    this._drumNeighborsApplied = true
    this._setStatus(`✓ ${this._drumAffectedNeighbors.length} vecini ajustați. Salvează când e gata.`, "ok")
    // Re-randează popup-ul în starea „applied" (afișează Salvează).
    this._showDrumParamsPopup()
  }

  _closeDrumPopup() {
    if (this._drumPopup) { try { this._drumPopup.remove() } catch (e) {} this._drumPopup = null }
  }

  // Re-rulează buffer_drum cu parametrii curenți. Restaurează vecinii la
  // poziția originală (înainte de orice modificare client-side), apoi aplică
  // rezultatul nou.
  async _recomputeDrum() {
    if (!this._drumOriginalLineWkt || !this._drumLastParams) return
    // Cleanup banda drumului anterioară DIN _drawSource (păstrând _axisFeature
    // dacă e acolo accidental). Modify pe axă rămâne intact.
    this._drawSource.getFeatures()
      .filter(f => f !== this._axisFeature)
      .forEach(f => this._drawSource.removeFeature(f))
    if (this._editVertexSource) this._editVertexSource.clear()
    this._currentFeature = null
    // Restore vecini la geometriile ORIGINALE (pre-orice modificare)
    this._restoreDrumNeighbors()
    this._drumMode = true
    // 3) Re-POST cu noile params
    const { widthM, snapDist } = this._drumLastParams
    this._setStatus(`Recalculare drum: lățime ${widthM}m · alipire ${snapDist}m…`)
    try {
      const res = await fetch(this.bufferDrumUrlValue, {
        method:  "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf(), "Accept": "application/json" },
        body:    JSON.stringify({ line_wkt: this._drumOriginalLineWkt, width_m: widthM, snap_dist_m: snapDist })
      })
      const data = await res.json()
      if (!data.ok) {
        this._setStatus(`Eroare recalcul: ${data.error || "necunoscută"}.`, "warn")
        return
      }
      const fmt = new ol.format.GeoJSON()
      this._drumCachedNeighbors = data.affected_neighbors || []
      this._drumAffectedNeighbors = null
      this._drumNeighborsApplied = false
      this._renderSnapZone(data.snap_zone_geojson)
      const polyFeat = fmt.readFeature(data.geojson, {
        dataProjection: "EPSG:3844", featureProjection: "EPSG:3844"
      })
      this._drawSource.addFeature(polyFeat)
      this._currentFeature = polyFeat
      this._extractVerts(polyFeat.getGeometry())
      // Curățăm cerculețele pe banda drumului — editare doar pe axă.
      if (this._editVertexSource) this._editVertexSource.clear()
      this._calcArea?.()
      this._showDrumParamsPopup()
      const nCached = this._drumCachedNeighbors.length
      this._setStatus(`✓ Drum recalculat: ${data.area_mp.toFixed(2)} m² · ${nCached} vecini detectați.`, "ok")
    } catch (e) {
      this._setStatus(`Eroare rețea: ${e.message}`, "warn")
    }
  }

  // Randează zona de prag alipire (inelul din jurul drumului) din GeoJSON.
  _renderSnapZone(geojson) {
    if (!this._snapZoneSource) return
    this._snapZoneSource.clear()
    if (!geojson) return
    try {
      const fmt = new ol.format.GeoJSON()
      const feat = fmt.readFeature(geojson, {
        dataProjection: "EPSG:3844", featureProjection: "EPSG:3844"
      })
      this._snapZoneSource.addFeature(feat)
    } catch (e) { console.warn("snap zone render failed:", e) }
  }

  // Re-generează banda drumului din axa modificată. Apelat când utilizatorul
  // trage un vertex al axei (modifyend event pe _axisModify).
  _regenFromAxis() {
    if (!this._axisFeature || !this._drumLastParams) return
    const geom = this._axisFeature.getGeometry()
    if (!geom || geom.getType() !== "LineString") return
    const coords = geom.getCoordinates() || []
    if (coords.length < 2) return
    this._drumOriginalLineWkt = "LINESTRING(" + coords.map(([x, y]) => `${x.toFixed(6)} ${y.toFixed(6)}`).join(", ") + ")"
    this._recomputeDrum()
  }

  // Restaurare vecini afectați (la cancel sau la clearAll în drum mode).
  _restoreDrumNeighbors() {
    if (!this._drumAffectedNeighbors) return
    this._drumAffectedNeighbors.forEach(n => {
      try {
        // Restaurăm geometria originală păstrând tipul (Polygon / MultiPolygon).
        const Cls = n.originalType === "MultiPolygon" ? ol.geom.MultiPolygon : ol.geom.Polygon
        n.feature.setGeometry(new Cls(n.originalCoords))
        if (n.deleteFlag && n.sourceLayer) {
          const src = n.sourceLayer
          if (!src.getFeatures().includes(n.feature)) {
            src.addFeature(n.feature)
          }
        }
      } catch (e) { console.warn("Restore failed for", n.kind, n.id, e) }
    })
    this._drumAffectedNeighbors = null
    this._drumMode = false
  }

  // Save dedicate pentru flow drum: creează drum nou + actualizează vecini
  // afectați ATOMIC. Înlocuiește submit-ul standard de formular parcelă.
  async _saveDrum() {
    if (!this._currentFeature) {
      this._setStatus("Niciun drum de salvat.", "warn")
      return
    }
    if (!this._drumOriginalLineWkt || !this._drumLastParams) {
      this._setStatus("Lipsesc parametrii drumului (axă/lățime). Reia desenul.", "warn")
      return
    }
    if (!await this._validateBeforeSave()) return

    // SECURITATE: NU mai trimitem geometria drumului sau a vecinilor — serverul
    // recalculează totul din axă + parametri (vezi save_drum + compute_drum_geometry).
    // Trimitem DOAR axa (line WKT), width, snap_dist și metadatele formularului.
    const form = this.saveFormTarget
    const fd = new FormData(form)
    const road = {
      cadgenno:            fd.get("land[numar_cadastral]") || "",
      suprafata_mp:        this._areaCalc > 0 ? this._areaCalc.toFixed(4) : "",
      categoria_folosinta: fd.get("land[categoria_folosinta]") || "DR"
    }
    const { widthM, snapDist } = this._drumLastParams
    const neighborCount = (this._drumAffectedNeighbors || []).length

    this._setStatus(`Salvare drum + ${neighborCount} vecin(i)…`)
    try {
      const res = await fetch(this.saveDrumUrlValue || "/digitizare/save_drum", {
        method:  "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf(), "Accept": "application/json" },
        body:    JSON.stringify({
          axis_wkt:    this._drumOriginalLineWkt,
          width_m:     widthM,
          snap_dist_m: snapDist,
          road
        })
      })
      const data = await res.json()
      if (data.ok) {
        const affected = data.affected_count ?? neighborCount
        this._setStatus(`✓ Drum salvat + ${affected} vecin(i) actualizați.`, "ok")
        this._drumMode = false
        this._drumAffectedNeighbors = null
        this.clearAll()
        // Reload TOATE layerele care pot conține vecini afectați:
        //   - parcelLayer: drafturi Lands cu gis_land_geometries cache
        //   - cladiriLayer: Buildings cache
        //   - cgxmlLayer: CGXML lands (cache + reconstruite din points)
        // CGXML lands afectate de drum acum au gis_land_geometries actualizat
        // → cgxmlLayer trebuie REÎNCĂRCAT pentru a vedea noile geometrii.
        this._hartaMap?._loadParcele?.()
        this._hartaMap?._loadCladiri?.()
        this._hartaMap?._loadCgxml?.()
        if (data.redirect && this._hartaMap) {
          const m2 = data.redirect.match(/\/lands\/(\d+)/)
          if (m2) {
            const mockSel = { kind: "parcela", feature: { get: (k) => k === "id" ? m2[1] : null } }
            this._hartaMap._updateFocusUrlParams?.(mockSel)
          }
        }
      } else {
        this._setStatus("Erori salvare: " + (data.errors || []).join(" | "), "warn")
      }
    } catch (e) {
      this._setStatus(`Eroare rețea: ${e.message}`, "warn")
    }
  }

  // Colectează toți vertecșii (ca puncte [x,y]) din feature-urile vecine
  // (parcele + cladiri + cgxml) — folosiți de _applyMetricSnapping pentru a
  // muta vertecșii desenați spre cei mai apropiați din raza metric configurată.
  _collectNeighborVerticesForMatch() {
    const out = []
    const refs = this._hartaMap
      ? [this._hartaMap.parcelLayer, this._hartaMap.cgxmlLayer, this._hartaMap.cladiriLayer]
      : []
    refs.forEach(layer => {
      layer?.getSource().getFeatures().forEach(f => {
        if (f === this._editFeature || f === this._currentFeature) return
        const geom = f.getGeometry?.()
        if (!geom) return
        const t = geom.getType()
        const rings = t === "Polygon" ? geom.getCoordinates()
                    : t === "MultiPolygon" ? geom.getCoordinates().flat()
                    : []
        rings.forEach(ring => {
          const v = ring.length > 1 ? ring.slice(0, -1) : ring
          v.forEach(c => out.push([c[0], c[1]]))
        })
      })
    })
    return out
  }

  // Match METRIC: pentru fiecare vertex curent (din _verts sau din _editFeature),
  // caută cel mai apropiat vertex existent din raza `meters`. Dacă găsește,
  // suprascrie coord cu vertex-ul existent EXACT. Returnează nr de potriviri.
  // Apelat doar din save flows când `_metricSnap.enabled = true`.
  _applyMetricSnapping() {
    if (!this._metricSnap?.enabled) return 0
    const meters = this._metricSnap.meters
    const targets = this._collectNeighborVerticesForMatch()
    if (targets.length === 0) return 0
    const findNearest = ([x, y]) => {
      let best = null, bestD = meters
      for (const [tx, ty] of targets) {
        const d = Math.hypot(tx - x, ty - y)
        if (d <= bestD) { bestD = d; best = [tx, ty] }
      }
      return best
    }

    let matched = 0
    // Cazul edit / post-draw modify: lucrăm pe geometria feature-ului.
    const targetFeat = this._editFeature || this._currentFeature
    if (targetFeat) {
      const geom = targetFeat.getGeometry()
      const type = geom.getType()
      let coords = null
      if (type === "Polygon") {
        coords = geom.getCoordinates().map(ring => {
          return ring.map(c => {
            const m = findNearest(c)
            if (m) { matched++; return m }
            return c
          })
        })
        geom.setCoordinates(coords)
      } else if (type === "MultiPolygon") {
        coords = geom.getCoordinates().map(poly => poly.map(ring => {
          return ring.map(c => {
            const m = findNearest(c)
            if (m) { matched++; return m }
            return c
          })
        }))
        geom.setCoordinates(coords)
      }
    }
    // Cazul draw nou (înainte de _onDrawEnd, dar la noi save vine după close):
    // sincronizăm _verts cu noua geometrie ca _buildWkt să folosească coords corecte.
    if (this._currentFeature) {
      const ring = this._currentFeature.getGeometry().getCoordinates()[0] || []
      const actual = ring.length > 1 ? ring.slice(0, -1) : ring
      this._verts = actual.map(c => ({ x: c[0], y: c[1] }))
    }
    return matched
  }

  closePolygon() {
    if (!this._draw) { this._setStatus("Nu există digitizare activă.", "warn"); return }
    if (this._verts.length < 3) { this._setStatus("Sunt necesare cel puțin 3 puncte.", "warn"); return }
    this._draw.finishDrawing()
  }

  undoVertex() {
    if (!this._draw) return
    this._draw.removeLastPoint()
    if (this._verts.length > 0) this._verts.pop()
    this._updateVertexList()
    if (this._verts.length >= 3) this._calcArea()
    else { this.areaCalcTarget.textContent = "—"; this.areaDiffTarget.textContent = "—" }
    this._setStatus(`Vertex eliminat. Rămân ${this._verts.length}.`)
  }

  clearAll() {
    // Restaurăm vecini afectați de drum dacă există (anulare digitizare drum)
    // + închidem popup-ul + curățăm axa drumului.
    if (this._drumAffectedNeighbors) this._restoreDrumNeighbors()
    this._closeDrumPopup?.()
    if (this._axisModify && this.map) {
      this.map.removeInteraction(this._axisModify)
      this._axisModify = null
    }
    if (this._axisSource) this._axisSource.clear()
    if (this._snapZoneSource) this._snapZoneSource.clear()
    this._axisFeature = null
    this._drumOriginalLineWkt = null
    this._drumLastParams = null
    this._drumCachedNeighbors = null
    this._drumNeighborsApplied = false
    this._drumMode = false
    this._verts    = []
    this._areaCalc = 0
    this._polygonValid = false
    this._polygonSimple = false
    this._topologyIssues = []
    this._topologyHasErrors = false
    if (this._draw && this.map) { this.map.removeInteraction(this._draw); this._draw = null }
    if (this._lineDraw && this.map) { this.map.removeInteraction(this._lineDraw); this._lineDraw = null }
    if (this.hasBtnLineDigitizeTarget) this.btnLineDigitizeTarget.classList.remove("btn-active")
    if (this._postDrawModify && this.map) { this.map.removeInteraction(this._postDrawModify); this._postDrawModify = null }
    if (this._geomChangeKey) { ol.Observable.unByKey(this._geomChangeKey); this._geomChangeKey = null }
    if (this._snap && this.map) { this.map.removeInteraction(this._snap); this._snap = null }
    // Curățare reziduuri de la operațiuni Mută/Rotește dacă au rămas active
    // (previne consumul primului click pe map de către alt interaction).
    if (this._postDrawTransform) this._cancelTransform?.()
    if (this._modify && this.map) { this.map.removeInteraction(this._modify); this._modify = null }
    this._currentFeature = null
    this._editing = false
    this._editFeature = null
    this._hartaMap?.setDigitizing(false)
    this._drawSource.clear()
    this._topoSource?.clear()
    this._editVertexSource?.clear()
    this._editEdgeLabelsSource?.clear()
    this.btnStartTarget.classList.remove("btn-active")
    this.btnCloseTarget.disabled = true
    this.btnUndoTarget.disabled  = true
    this._updateSaveAvailability()
    this._updateVertexList()
    this._updateToolbarVisibility?.()
    this.areaCalcTarget.textContent  = "—"
    this.areaDiffTarget.textContent  = "—"
    if (this.hasAreaActTarget)        this.areaActTarget.value = ""
    this.topologyMsgTarget.textContent = ""
    if (this.hasStatusAreaTarget) this.statusAreaTarget.textContent = "—"
    // Resetăm starea de selecție + formularul ca să nu rămână câmpurile
    // populate cu date din parcela anterior selectată (proprietar, judet,
    // localitate, suprafață etc.) — risc de save accidental cu valori vechi.
    this._selected = null
    this._hartaMap?.clearSelection?.()
    this._hartaMap?._updateFocusUrlParams?.(null)
    this._clearSelectionForm()
    this._updateEditButton()
    this._updateToolbarVisibility?.()
    this._setStatus("Toți vertecșii au fost șterși.")
  }

  addManualPoint() {
    const x = parseFloat(this.inputXTarget.value)
    const y = parseFloat(this.inputYTarget.value)
    if (isNaN(x) || isNaN(y)) { this._setStatus("Coordonate invalide.", "warn"); return }
    if (!this._draw) { this._setStatus("Pornește digitizarea înainte să adaugi puncte.", "warn"); return }
    this._draw.appendCoordinates([[x, y]])  // direct în Stereo 70
    this.inputXTarget.value = ""
    this.inputYTarget.value = ""
    this.inputXTarget.focus()
  }

  importTxt(event) {
    const file = event.target.files[0]
    if (!file) return
    if (!this._draw) { this._setStatus("Pornește digitizarea înainte să imporți.", "warn"); event.target.value = ""; return }
    const reader = new FileReader()
    reader.onload = (e) => {
      const pts = this._parseTxt(e.target.result)
      if (!pts.length) { this._setStatus("Fișier TXT fără date valide.", "warn"); return }
      this._draw.appendCoordinates(pts.map(({ x, y }) => [x, y]))  // direct în Stereo 70
      this._setStatus(`${pts.length} puncte importate din ${file.name}.`, "ok")
      event.target.value = ""
    }
    reader.readAsText(file)
  }

  toleranceChanged() {
    this.snapToleranceValue = parseInt(this.snapSliderTarget.value)
    this.snapToleranceValTarget.textContent = this.snapToleranceValue
    if (this._draw || this._editing || this._postDrawModify) this._refreshSnap()
  }

  // Toggle pixel ↔ metric snap. Activarea dezactivează slider-ul în pixeli
  // (vizual disable) și activează slider-ul în metri.
  onMetricSnapToggle(evt) {
    this._metricSnap.enabled = !!evt.target.checked
    if (this.hasMetricSnapSliderTarget) this.metricSnapSliderTarget.disabled = !this._metricSnap.enabled
    if (this.hasSnapSliderTarget)       this.snapSliderTarget.disabled       =  this._metricSnap.enabled
    this._persistMetricSnap()
    if (this._draw || this._editing || this._postDrawModify) this._refreshSnap()
  }

  onMetricSnapChange() {
    if (!this.hasMetricSnapSliderTarget) return
    this._metricSnap.meters = parseFloat(this.metricSnapSliderTarget.value)
    if (this.hasMetricSnapValTarget) this.metricSnapValTarget.textContent = this._metricSnap.meters.toFixed(1)
    this._persistMetricSnap()
    if (this._metricSnap.enabled && (this._draw || this._editing || this._postDrawModify)) this._refreshSnap()
  }

  _persistMetricSnap() {
    try { localStorage.setItem("harta:metricSnap", JSON.stringify(this._metricSnap)) } catch (_) { /* no-op */ }
  }

  // Sincronizează UI cu starea metric-snap restaurată din localStorage (apel
  // la connect, după ce target-urile sunt disponibile).
  // ── Floating toolbar: drag + persistență + vizibilitate contextuală ────

  onToolbarGripDown(evt) {
    if (!this.hasMapToolbarTarget) return
    evt.preventDefault()
    const tb   = this.mapToolbarTarget
    const rect = tb.getBoundingClientRect()
    const offX = evt.clientX - rect.left
    const offY = evt.clientY - rect.top
    tb.classList.add("is-dragging")

    const onMove = (e) => {
      const parent = tb.offsetParent || document.body
      const pr = parent.getBoundingClientRect()
      let x = e.clientX - pr.left - offX
      let y = e.clientY - pr.top  - offY
      // clamp în viewport
      x = Math.max(0, Math.min(x, parent.clientWidth  - tb.offsetWidth))
      y = Math.max(0, Math.min(y, parent.clientHeight - tb.offsetHeight))
      tb.style.left   = `${x}px`
      tb.style.top    = `${y}px`
      tb.style.right  = "auto"
      tb.style.bottom = "auto"
    }
    const onUp = () => {
      tb.classList.remove("is-dragging")
      document.removeEventListener("mousemove", onMove)
      document.removeEventListener("mouseup",   onUp)
      try {
        localStorage.setItem("harta:toolbarPos", JSON.stringify({
          left: tb.style.left, top: tb.style.top
        }))
      } catch (_) { /* no-op */ }
    }
    document.addEventListener("mousemove", onMove)
    document.addEventListener("mouseup",   onUp)
  }

  _restoreToolbarPosition() {
    if (!this.hasMapToolbarTarget) return
    try {
      const saved = JSON.parse(localStorage.getItem("harta:toolbarPos") || "null")
      if (saved && saved.left && saved.top) {
        this.mapToolbarTarget.style.left   = saved.left
        this.mapToolbarTarget.style.top    = saved.top
        this.mapToolbarTarget.style.right  = "auto"
        this.mapToolbarTarget.style.bottom = "auto"
      }
    } catch (_) { /* no-op */ }
  }

  // Ascunde butoanele neaplicabile contextual:
  //  - Editare/Mută/Șterge: doar când există o selecție
  //  - Închide/Undo: doar în timpul desenării
  //  - Șterge bulk: doar în multi-select mode + cu items selectate
  _updateToolbarVisibility() {
    const hide = (target, condition) => {
      const el = this[`has${target}Target`] ? this[`${target[0].toLowerCase()}${target.slice(1)}Target`] : null
      if (el) el.classList.toggle("map-tb-btn--hidden", !condition)
    }
    // Edit / Delete = single-feature only (cer un `_selected`).
    hide("BtnEdit",   !!this._selected)
    hide("BtnDelete", !!this._selected)
    // Move / Rotate = single SAU bulk (multi-select cu items).
    const multiCount  = this._hartaMap?.getMultiSelection?.()?.length || 0
    const hasTransformSel = !!this._selected || (this._multiSelectActive && multiCount > 0)
    hide("BtnMove",   hasTransformSel)
    hide("BtnRotate", hasTransformSel)
    hide("BtnClose",  !!this._draw)
    hide("BtnUndo",   !!this._draw)
    // btnDeleteMulti rămâne controlat prin atribut hidden direct în _onMultiSelectionChanged
  }

  _syncMetricSnapUI() {
    if (this.hasMetricSnapToggleTarget) this.metricSnapToggleTarget.checked = !!this._metricSnap.enabled
    if (this.hasMetricSnapSliderTarget) {
      this.metricSnapSliderTarget.value    = this._metricSnap.meters
      this.metricSnapSliderTarget.disabled = !this._metricSnap.enabled
    }
    if (this.hasMetricSnapValTarget) this.metricSnapValTarget.textContent = this._metricSnap.meters.toFixed(1)
    if (this.hasSnapSliderTarget)    this.snapSliderTarget.disabled       =  this._metricSnap.enabled
  }

  updateDiff() { this._updateDiffDisplay() }

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
      Object.assign(document.createElement("a"), { href: url, download: "parcela.dxf" }).click()
      URL.revokeObjectURL(url)
    } catch (e) { this._setStatus("Eroare export DXF: " + e.message, "warn") }
  }

  showRaport() {
    if (this._verts.length < 3) { this._setStatus("Niciun poligon de raportat.", "warn"); return }
    const win = window.open("", "_blank")
    win.document.write(this._buildRaportHtml())
    win.document.close()
  }

  async saveParcel() {
    // Mod drum (digitizare detaliu liniar) → flow dedicat care actualizează
    // și vecinii afectați în aceeași tranzacție.
    if (this._drumMode) return this._saveDrum()
    if (!await this._validateBeforeSave()) return
    const m = this._applyMetricSnapping()
    if (m) this._setStatus(`METRIC: ${m} vertex(i) potriviți pe vecini.`, "ok")
    this.wktFieldTarget.value      = this._buildWkt("MULTIPOLYGON")
    this.saveAreaFieldTarget.value = this._areaCalc > 0 ? this._areaCalc.toFixed(4) : ""
    await this._submitNewFeatureAjax(this.saveFormTarget, "parcela")
  }

  async saveBuilding() {
    if (!await this._validateBeforeSave()) return
    const m = this._applyMetricSnapping()
    if (m) this._setStatus(`METRIC: ${m} vertex(i) potriviți pe vecini.`, "ok")
    this.wktFieldCladireTarget.value      = this._buildWkt("MULTIPOLYGON")
    this.saveAreaFieldCladireTarget.value = this._areaCalc > 0 ? this._areaCalc.toFixed(4) : ""
    await this._submitNewFeatureAjax(this.saveFormCladireTarget, "cladire")
  }

  // Submit AJAX al formularului parcelă/clădire — rămâne pe /harta, reload
  // layere și status în panou (fără navigare la /lands/:id sau /buildings/:id).
  async _submitNewFeatureAjax(form, kind) {
    try {
      this._setStatus(`Salvare ${kind}…`)
      const fd  = new FormData(form)
      const res = await fetch(form.action, {
        method:  form.method?.toUpperCase() || "POST",
        body:    fd,
        headers: { "X-CSRF-Token": this._csrf(), "Accept": "application/json" }
      })
      const data = await res.json().catch(() => ({}))
      if (res.ok && data.ok) {
        this._setStatus(`✓ ${kind === "cladire" ? "Clădirea" : "Parcela"} a fost salvată.`, "ok")
        this.clearAll()
        // Persistă noul poligon în URL — la refresh, ecranul se centrează
        // pe el. `clearAll` a șters URL-ul; setăm DUPĂ. Resetăm și
        // `_zoomedFromUrl` ca să se aplice zoom imediat după reload.
        const m = data.redirect?.match(/\/(lands|buildings)\/(\d+)/)
        if (m && this._hartaMap) {
          const newKind = m[1] === "buildings" ? "cladire" : "parcela"
          const mockSel = { kind: newKind, feature: { get: (k) => k === "id" ? m[2] : null } }
          this._hartaMap._updateFocusUrlParams?.(mockSel)
          this._hartaMap._zoomedFromUrl = false
        }
        // Reload layere ca să apară noul poligon
        this._hartaMap?._loadParcele?.()
        this._hartaMap?._loadCladiri?.()
        this._hartaMap?._loadCgxml?.()
      } else {
        const errs = (data.errors || []).join(" | ") || `HTTP ${res.status}`
        this._setStatus(`Eroare la salvare: ${errs}`, "warn")
      }
    } catch (e) {
      this._setStatus(`Eroare rețea: ${e.message}`, "warn")
    }
  }

  // Forțează o validare sincronă proaspătă înainte să accepte save (anti-race)
  async _validateBeforeSave() {
    if (this._verts.length < 3) {
      this._setStatus("Niciun poligon pentru salvare (minim 3 vertecși).", "warn")
      return false
    }
    clearTimeout(this._areaDebounce)
    clearTimeout(this._topoDebounce)
    this._setStatus("Verificare topologie…")
    await this._calcArea()
    await this._verifyTopology()
    return await this._guardSavable()
  }

  async _guardSavable() {
    if (this._verts.length < 3) {
      this._setStatus("Niciun poligon pentru salvare (minim 3 vertecși).", "warn")
      return false
    }
    if (!this._polygonValid) {
      this._setStatus("Poligon INVALID (auto-intersecție / topologie eronată) — corectează vertecșii înainte de salvare.", "warn")
      return false
    }
    if (!this._polygonSimple) {
      this._setStatus("Poligon NON-SIMPLU — corectează vertecșii înainte de salvare.", "warn")
      return false
    }
    if (this._topologyHasErrors) {
      const errs = this._topologyIssues.filter(i => i.severity === "error")
      const fixables  = errs.filter(i => i.fixable)
      const hardBlock = errs.filter(i => !i.fixable)
      if (hardBlock.length > 0) {
        this._setStatus(`Conflict topologic: ${hardBlock.length} eroare(i) > 1 mp — corectează manual și vezi panoul.`, "warn")
        return false
      }
      if (fixables.length > 0) {
        // Toate erorile sunt ≤ 1 mp (goluri sau suprapuneri) → întreabă user-ul.
        const totals = {
          slivers:  fixables.filter(i => i.type === "sliver").length,
          overlaps: fixables.filter(i => i.type === "overlap").length
        }
        const parts = []
        if (totals.slivers)  parts.push(`${totals.slivers} gol(uri)`)
        if (totals.overlaps) parts.push(`${totals.overlaps} suprapunere(i)`)
        const ans = confirm(
          `Detectat ${parts.join(" + ")} ≤ 1 mp cu vecinii.\n\n` +
          `OK = fixează automat (snap vertecși pe vecini + elimină ≤ 1 mp) și salvează\n` +
          `Anulează = salvează cu erorile actuale (toleranță ≤ 1 mp acceptată)`
        )
        if (ans) {
          // Force METRIC snap radius 1.0 m pentru auto-fix; restaurează după.
          const oldEnabled = this._metricSnap?.enabled
          const oldRadius  = this._metricSnap?.meters
          this._metricSnap = { enabled: true, meters: 1.0 }
          const m = this._applyMetricSnapping()
          this._metricSnap = { enabled: oldEnabled, meters: oldRadius || 0.5 }
          this._setStatus(`Auto-fix: ${m} vertex(i) potriviți pe vecini.`, "ok")
          await this._verifyTopology()
        }
      }
    }
    return true
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

  // ── Snap multi-mode ──────────────────────────────────────────────────────

  _refreshSnap() {
    if (!this.map) return
    if (this._snap) this.map.removeInteraction(this._snap)
    const features = this._buildSnapFeatures()
    this._snap = new ol.interaction.Snap({
      features:       new ol.Collection(features),
      pixelTolerance: this.snapToleranceValue,
      vertex:         this._snapModes.has("endpoint") || this._snapModes.has("midpoint") || this._snapModes.has("centroid"),
      edge:           this._snapModes.has("nearest")
    })
    this._snap.setActive(this._snapEnabled)
    this.map.addInteraction(this._snap)
  }

  _buildSnapFeatures() {
    if (!this._hartaMap) return []
    const out  = []
    const refs = [this._hartaMap.parcelLayer, this._hartaMap.cgxmlLayer, this._hartaMap.cladiriLayer]
    const m    = this._snapModes
    // Excludem poligoanele AFLATE ÎN MIȘCARE — altfel OL Snap se prinde de
    // propriul vertex al poligonului mutat (care e suprapus pe destinație
    // după translație) → niciodată nu ajunge la vertex de destinație.
    const movingFeatures = new Set()
    if (this._moveOp?.items) this._moveOp.items.forEach(it => movingFeatures.add(it.feature))
    // _bulkOp există atât în timpul mutării (post-_moveOp) cât și după commit
    // când avem editare de vertecși. În al doilea caz (snapIncludeBulkItems=true)
    // includem items ca să se poată snap-ui vertex-on-vertex între ele.
    if (this._bulkOp?.items && !this._snapIncludeBulkItems) {
      this._bulkOp.items.forEach(it => movingFeatures.add(it.feature))
    }
    refs.forEach(layer => {
      layer.getSource().getFeatures().forEach(f => {
        if (movingFeatures.has(f)) return
        if (m.has("endpoint") || m.has("nearest")) out.push(f)
        if (m.has("midpoint")) this._addMidpoints(f, out)
        if (m.has("centroid")) this._addCentroid(f, out)
      })
    })
    return out
  }

  _addMidpoints(feature, out) {
    const geom = feature.getGeometry()
    if (!geom) return
    const t = geom.getType()
    const rings = t === "Polygon"      ? geom.getCoordinates()
                : t === "MultiPolygon" ? geom.getCoordinates().flat()
                : []
    rings.forEach(ring => {
      for (let i = 0; i < ring.length - 1; i++) {
        const mx = (ring[i][0] + ring[i + 1][0]) / 2
        const my = (ring[i][1] + ring[i + 1][1]) / 2
        out.push(new ol.Feature(new ol.geom.Point([mx, my])))
      }
    })
  }

  _addCentroid(feature, out) {
    const geom = feature.getGeometry()
    if (!geom) return
    const ext = geom.getExtent()
    const center = ol.extent.getCenter(ext)
    out.push(new ol.Feature(new ol.geom.Point(center)))
  }

  // ── Linia de comandă (parser absolut / relativ / polar) ──────────────────

  _parseCmd(raw) {
    // Direct distance entry (CAD): doar număr → folosește direcția cursorului
    if (/^-?\d+(\.\d+)?$/.test(raw)) {
      const dist = parseFloat(raw)
      if (isNaN(dist) || this._verts.length === 0 || !this._cursorStereo) return null
      const last = this._verts[this._verts.length - 1]
      let dx = this._cursorStereo.x - last.x
      let dy = this._cursorStereo.y - last.y
      if (this._orthoEnabled) {
        if (Math.abs(dx) > Math.abs(dy)) dy = 0
        else dx = 0
      }
      const len = Math.sqrt(dx * dx + dy * dy)
      if (len === 0) return null
      return { x: last.x + dist * dx / len, y: last.y + dist * dy / len }
    }

    if (raw.startsWith("@")) {
      if (this._verts.length === 0) return null
      const last = this._verts[this._verts.length - 1]
      const rest = raw.slice(1)
      if (rest.includes("<")) {
        // Polar: lungime<unghi (grade, 0=N, 90=E, sens orar)
        const [lenS, angS] = rest.split("<")
        const len = parseFloat(lenS), ang = parseFloat(angS)
        if (isNaN(len) || isNaN(ang)) return null
        const rad = ang * Math.PI / 180
        return { x: last.x + len * Math.sin(rad), y: last.y + len * Math.cos(rad) }
      } else {
        const [dxS, dyS] = rest.replace(/,/g, " ").split(/\s+/)
        const dx = parseFloat(dxS), dy = parseFloat(dyS)
        if (isNaN(dx) || isNaN(dy)) return null
        return { x: last.x + dx, y: last.y + dy }
      }
    } else {
      const parts = raw.replace(/,/g, " ").split(/\s+/).filter(Boolean)
      if (parts.length < 2) return null
      const x = parseFloat(parts[0]), y = parseFloat(parts[1])
      if (isNaN(x) || isNaN(y)) return null
      return { x, y }
    }
  }

  // ── Ortho mode (constrânge desenul la 90°) ───────────────────────────────

  // Pentru type 'Polygon', OL trimite `coordinates = [openRing]` unde openRing
  // este array de [x, y] (vertecși confirmați + cursor). Funcția implicită
  // închide ring-ul prin append la primul vertex.
  _buildGeometryFunction() {
    return (coordinates, geometry) => {
      let ring = coordinates[0]
      if (this._orthoEnabled && ring.length >= 2) {
        const last = ring[ring.length - 1]
        const prev = ring[ring.length - 2]
        const dx = Math.abs(last[0] - prev[0])
        const dy = Math.abs(last[1] - prev[1])
        const fixed = dx > dy ? [last[0], prev[1]] : [prev[0], last[1]]
        ring = [...ring.slice(0, -1), fixed]
      }
      // Închide ring-ul (append primul vertex la final)
      const closed = ring.length > 0 ? [...ring, ring[0]] : ring
      if (!geometry) geometry = new ol.geom.Polygon([closed])
      else geometry.setCoordinates([closed])
      return geometry
    }
  }

  // ── Map handlers ─────────────────────────────────────────────────────────

  _onPointerMove(evt) {
    // View-ul OL e în EPSG:3844 → evt.coordinate e DIRECT în Stereo 70 (m), fără transform.
    const [x, y] = evt.coordinate
    this._cursorStereo = { x, y }
    if (this.hasStatusXTarget) this.statusXTarget.textContent = FMT(x)
    if (this.hasStatusYTarget) this.statusYTarget.textContent = FMT(y)
  }

  _updateScale() {
    if (!this.map || !this.hasStatusScaleTarget) return
    const view = this.map.getView()
    const res  = view.getResolution()
    const mpu  = view.getProjection().getMetersPerUnit() || 1
    // Ecran: 96 dpi → 39.37 inch/m
    const scale = res * mpu * 39.37 * 96
    this.statusScaleTarget.textContent = scale > 1000 ? Math.round(scale / 100) * 100 : Math.round(scale)
  }

  _onDrawStart(evt) {
    this._currentFeature = evt.feature
    // Extragem vertecșii inițiali — OL a creat deja geometria înainte de drawstart,
    // deci listener-ul de „change" nu vede primul vertex (ar pierde populația _verts)
    this._extractVerts(this._currentFeature.getGeometry())
    this._geomChangeKey = this._currentFeature.getGeometry().on("change", (e) => {
      this._extractVerts(e.target)
      if (this._verts.length >= 3) {
        clearTimeout(this._areaDebounce)
        this._areaDebounce = setTimeout(() => this._calcArea(), 400)
        clearTimeout(this._topoDebounce)
        this._topoDebounce = setTimeout(() => this._verifyTopology(), 700)
      }
      // Update vecinii vizuali pe măsură ce poligonul crește (bbox-ul se extinde)
      clearTimeout(this._neighborDebounce)
      this._neighborDebounce = setTimeout(() => this._refreshDrawVisualNeighbors(), 250)
    })
    // Inițial — fără vecini (bbox prea mic), dar pregătim source-ul.
    this._refreshDrawVisualNeighbors()
  }

  // Re-randează vertecșii vecinilor (cerculețe gri-bleu) în jurul poligonului
  // în curs de desenare/post-draw. Cheamă `_findVisualNeighbors` care folosește
  // JSTS pentru detecție de tip „lipit" cu toleranță 5 cm. În mod draw poligonul
  // crește treptat — refacem la fiecare schimbare de geometrie (debounced).
  _refreshDrawVisualNeighbors() {
    if (!this._currentFeature || !this._editVertexSource) return
    // Curățăm doar entrările visualNeighbor (păstrăm vertecșii primarului)
    const keep = this._editVertexSource.getFeatures().filter(f => !f.get("visualNeighbor"))
    this._editVertexSource.clear()
    keep.forEach(f => this._editVertexSource.addFeature(f))
    const visual = this._findVisualNeighbors(this._currentFeature)
    this._renderVisualNeighborVertices(visual)
  }

  _onDrawEnd(evt) {
    if (this._geomChangeKey) ol.Observable.unByKey(this._geomChangeKey)

    // Re-extragem _verts din geometria FINALĂ (închisă, fără cursor live).
    // OL.finishDrawing pop-uiește cursor-ul ÎNAINTE să închidă ring-ul, dar
    // ultima dată când change event a fost prins în handler-ul nostru, _draw
    // era încă activ → _extractVerts elimina și ultimul vertex real ca pe cursor.
    const feature = evt.feature
    const ring = feature.getGeometry().getCoordinates()[0] || []
    this._verts = (ring.length > 1 ? ring.slice(0, -1) : ring).map(c => ({ x: c[0], y: c[1] }))
    this._polygonValid      = false
    this._polygonSimple     = false
    this._topologyHasErrors = true
    this._renderEditVertices()
    this._updateVertexList()
    this._updateLiveArea()
    this._updateSaveAvailability()

    if (this._draw && this.map) { this.map.removeInteraction(this._draw); this._draw = null }
    this.btnCloseTarget.disabled = true
    this.btnStartTarget.classList.remove("btn-active")

    // Permite ajustarea poligonului proaspăt desenat — drag pe vertex,
    // click pe muchie + drag pentru vertex nou, Shift/Alt+click pentru
    // ștergere — TOATE până la save (forma se redesenează live, area și
    // topology re-verificate la fiecare schimbare).
    this._postDrawModify = new ol.interaction.Modify({
      features:       new ol.Collection([feature]),
      pixelTolerance: 12,
      deleteCondition: (e) => {
        const oe = e.originalEvent
        return e.type === "singleclick" && (oe?.shiftKey || oe?.altKey)
      }
    })
    this.map.addInteraction(this._postDrawModify)
    this._refreshSnap()  // snap-ul rămâne activ pentru ajustări

    // Re-atașăm geom-change listener → _verts + area + topology live, plus
    // re-randare vecini vizuali (poligonul poate fi mutat/transformat în
    // post-draw modify).
    this._geomChangeKey = feature.getGeometry().on("change", (e) => {
      this._extractVerts(e.target)
      clearTimeout(this._areaDebounce); clearTimeout(this._topoDebounce)
      this._areaDebounce = setTimeout(() => this._calcArea(), 400)
      this._topoDebounce = setTimeout(() => this._verifyTopology(), 700)
      clearTimeout(this._neighborDebounce)
      this._neighborDebounce = setTimeout(() => this._refreshDrawVisualNeighbors(), 250)
    })

    // Vecini vizuali finali (după închidere)
    this._refreshDrawVisualNeighbors()

    // Păstrăm digitizing=true cât timp poligonul nu e salvat — astfel hover
    // pe vecini nu deschide popup (interferează cu post-draw modify).
    // setDigitizing(false) se face la Save (clearAll după AJAX) sau Cancel.
    this._setStatus(`Poligon închis — ${this._verts.length} vertecși. Poți încă ajusta vertecșii înainte de save.`, "ok")
    this._calcArea()
    this._verifyTopology()
    this._locateUat()
  }

  _extractVerts(geom) {
    // Suport pentru ambele tipuri de geometrii:
    // - Polygon (la digitizare nouă):   getCoordinates() = [ring, hole?...]
    // - MultiPolygon (la edit din DB):  getCoordinates() = [[ring, hole?...], [...], ...]
    const type = geom.getType()
    let ring = []
    if (type === "MultiPolygon") {
      ring = geom.getCoordinates()[0]?.[0] || []
    } else if (type === "Polygon") {
      ring = geom.getCoordinates()[0] || []
    }
    // Format ring în timpul desenării: [v1, v2, ..., vN, cursor, v1]
    // Format după finishDrawing / din DB: [v1, v2, ..., vN, v1]
    // Eliminăm întotdeauna ultimul (closing duplicate); dacă desenarea e activă
    // mai eliminăm încă unul (cursor live) ca să rămână doar vertecșii confirmați.
    let actual = ring.length > 1 ? ring.slice(0, -1) : ring
    if (this._draw && actual.length > 1) actual = actual.slice(0, -1)

    // Coords ring sunt deja în EPSG:3844 (view-ul e în Stereo 70), zero round-trip.
    this._verts = actual.map((c) => ({ x: c[0], y: c[1] }))
    // Pesimist: fiecare modificare geometrică invalidează rezultatul anterior
    // de validare. _calcArea + _verifyTopology vor seta valorile la răspunsul PostGIS.
    this._polygonValid      = false
    this._polygonSimple     = false
    this._topologyHasErrors = true
    this._updateSaveAvailability()
    this._updateVertexList()
    this._updateLiveArea()
    this._renderEditVertices()  // cerculețe roșii la vertecșii confirmați (ambele moduri)
  }

  _updateLiveArea() {
    if (!this.hasStatusAreaTarget) return
    if (this._verts.length < 3) { this.statusAreaTarget.textContent = "—"; return }
    // Calcul aproximativ Stereo70 (proiecție conformă pe România → suficient pentru live preview)
    const ring = [...this._verts.map(v => [v.x, v.y]), [this._verts[0].x, this._verts[0].y]]
    let area = 0
    for (let i = 0; i < ring.length - 1; i++) {
      area += ring[i][0] * ring[i + 1][1] - ring[i + 1][0] * ring[i][1]
    }
    area = Math.abs(area) / 2
    this.statusAreaTarget.textContent = `${FMT2(area)} mp`
  }

  _drawStyle(feature) {
    const type = feature.getGeometry()?.getType()
    // OL Draw creează intern 3 features: Polygon (constrâns prin geometryFunction),
    // LineString preview de la ultimul vertex la cursor (RAW, neconstrâns), și
    // Point la cursor. În modul ortho, ascundem LineString-ul ca să nu se vadă
    // o a doua linie pe direcția liberă a cursorului.
    if (this._orthoEnabled && type === "LineString") return null

    // Sketch point la cursor (Point feature): mai mare + cruciuliță pentru
    // vizibilitate maximă — utilizatorul vede CLAR unde va fi următorul vertex.
    if (type === "Point") {
      return [
        new ol.style.Style({
          image: new ol.style.Circle({
            radius: 7,
            fill:   new ol.style.Fill({ color: "rgba(29, 78, 216, 0.4)" }),
            stroke: new ol.style.Stroke({ color: "#ffffff", width: 2 })
          })
        }),
        new ol.style.Style({
          image: new ol.style.RegularShape({
            points: 4, radius: 11, radius2: 0, angle: 0,  // cruciuliță „+"
            stroke: new ol.style.Stroke({ color: "#1d4ed8", width: 1.5 })
          })
        })
      ]
    }

    return new ol.style.Style({
      stroke: new ol.style.Stroke({ color: "#1d4ed8", width: 2 }),
      fill:   new ol.style.Fill({ color: "rgba(147, 197, 253, 0.25)" }),
      image:  new ol.style.Circle({
        radius: 5,
        fill:   new ol.style.Fill({ color: "#1d4ed8" }),
        stroke: new ol.style.Stroke({ color: "#fff", width: 2 })
      })
    })
  }

  // ── Locate UAT ───────────────────────────────────────────────────────────

  async _locateUat() {
    if (!this.locateUatUrlValue || this._verts.length < 3) return
    try {
      const res = await fetch(this.locateUatUrlValue, {
        method:  "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf() },
        body:    JSON.stringify({ coords: this._verts.map(v => [v.x, v.y]) })
      })
      const data = await res.json()
      if (!data.judet) return
      this.element.querySelectorAll('[data-siruta-target="judetInput"]').forEach(el => this._flashFill(el, data.judet))
      this.element.querySelectorAll('[data-siruta-target="localitateInput"]').forEach(el => this._flashFill(el, data.localitate))
    } catch (e) { console.warn("Locate UAT error:", e) }
  }

  _flashFill(input, value) {
    input.value = value
    input.classList.add("digi-autofill")
    setTimeout(() => input.classList.remove("digi-autofill"), 1800)
  }

  // ── Vertex list UI ───────────────────────────────────────────────────────

  _updateVertexList() {
    if (this.hasVertexTbodyTarget) {
      const tbody = this.vertexTbodyTarget
      tbody.innerHTML = ""
      this._verts.forEach((v, i) => {
        const tr = document.createElement("tr")
        tr.innerHTML = `<td class="vt-no">${i + 1}</td><td class="vt-coord">${FMT(v.x)}</td><td class="vt-coord">${FMT(v.y)}</td><td></td>`
        tbody.appendChild(tr)
      })
    }
    if (this.hasVertexCountTarget) this.vertexCountTarget.textContent = this._verts.length
  }

  // ── Area calc + diferență ────────────────────────────────────────────────

  async _calcArea() {
    if (this._verts.length < 3) return
    try {
      const res = await fetch(this.calcUrlValue, {
        method:  "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf() },
        body:    JSON.stringify({ coords: this._verts.map(v => [v.x, v.y]) })
      })
      const data = await res.json()
      this._areaCalc      = data.suprafata || 0
      this._polygonValid  = data.is_valid  !== false
      this._polygonSimple = data.is_simple !== false
      this.areaCalcTarget.textContent = this._areaCalc > 0 ? `${FMT2(this._areaCalc)} mp` : "—"
      const msgs = []
      if (data.is_valid  === false) msgs.push("⚠ Poligon invalid (auto-intersecție)")
      if (data.is_simple === false) msgs.push("⚠ Poligon non-simplu")
      this.topologyMsgTarget.innerHTML = msgs.map(m => `<span class="topo-warn">${m}</span>`).join("")
      this._updateSaveAvailability()
      this._updateDiffDisplay()
    } catch (e) { console.warn("Eroare calcul suprafață:", e) }
  }

  _isPolygonSavable() {
    return this._verts.length >= 3
      && this._polygonValid
      && this._polygonSimple
      && !this._topologyHasErrors
  }

  // ── Verificare topologie cu vecini (overlap, sliver, vertex-on-vertex) ──

  async _verifyTopology() {
    if (!this.hasVerificaUrlValue || this._verts.length < 3) return
    try {
      const res = await fetch(this.verificaUrlValue, {
        method:  "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf() },
        body:    JSON.stringify(this._verifyTopologyParams())
      })
      const data = await res.json()
      this._topologyIssues    = data.issues || []
      this._topologyHasErrors = !!data.has_errors
      this._renderTopologyIssues()
      this._updateSaveAvailability()
    } catch (e) {
      console.warn("Topology check error:", e)
    }
  }

  _renderTopologyIssues() {
    this._topoSource.clear()
    const fmt = new ol.format.GeoJSON()
    this._topologyIssues.forEach(issue => {
      if (!issue.geojson) return
      try {
        const feat = fmt.readFeature(issue.geojson, {
          dataProjection:    "EPSG:3844",
          featureProjection: "EPSG:3844"
        })
        feat.set("severity", issue.severity)
        feat.set("issueType", issue.type)
        feat.set("message",  issue.message)
        this._topoSource.addFeature(feat)
      } catch (e) { /* skip un-parsable */ }
    })
    this._renderTopologyPanel()
  }

  _renderTopologyPanel() {
    const errs  = this._topologyIssues.filter(i => i.severity === "error")
    const warns = this._topologyIssues.filter(i => i.severity === "warning")
    const html  = []
    if (errs.length === 0 && warns.length === 0) {
      // Show "OK" message when no issues
      if (this._verts.length >= 3) {
        html.push(`<span class="topo-ok">✓ Topologie OK (fără conflicte cu vecini)</span>`)
      }
    } else {
      if (errs.length)  html.push(`<div class="topo-error-header">⛔ ${errs.length} eroare(i):</div>`)
      errs.forEach(e  => html.push(`<span class="topo-warn topo-error-item">• ${e.message}</span>`))
      if (warns.length) html.push(`<div class="topo-warn-header">⚠ ${warns.length} avertizare(i):</div>`)
      warns.forEach(w => html.push(`<span class="topo-warn">• ${w.message}</span>`))
    }
    const out = html.join("")
    this.topologyMsgTarget.innerHTML = out
    // Mirror în panoul de edit (vizibil la top)
    if (this.hasEditTopoMirrorTarget) this.editTopoMirrorTarget.innerHTML = out
  }

  _topoStyle(feature) {
    const sev  = feature.get("severity")
    const type = feature.get("issueType")
    if (sev === "error") {
      // Overlap rosu pulsant + bordura groasă
      return new ol.style.Style({
        stroke: new ol.style.Stroke({ color: "#dc2626", width: 3 }),
        fill:   new ol.style.Fill({ color: "rgba(220, 38, 38, 0.45)" })
      })
    }
    if (type === "vertex_off") {
      // Vertex NOU pe muchia vecinului — portocaliu (problema noului poligon)
      return new ol.style.Style({
        image: new ol.style.Circle({
          radius: 7,
          fill:   new ol.style.Fill({ color: "#d97706" }),
          stroke: new ol.style.Stroke({ color: "#fff", width: 2 })
        })
      })
    }
    if (type === "neighbor_vertex_off") {
      // Vertex VECIN pe muchia ta — albastru (trebuie adăugat ca vertex propriu)
      return new ol.style.Style({
        image: new ol.style.Circle({
          radius: 7,
          fill:   new ol.style.Fill({ color: "#2563eb" }),
          stroke: new ol.style.Stroke({ color: "#fff", width: 2 })
        })
      })
    }
    // sliver / alte warnings
    return new ol.style.Style({
      stroke: new ol.style.Stroke({ color: "#d97706", width: 2, lineDash: [4, 4] }),
      fill:   new ol.style.Fill({ color: "rgba(251, 191, 36, 0.25)" })
    })
  }

  _updateSaveAvailability() {
    const ok = this._isPolygonSavable()
    this.element.querySelectorAll('[data-action*="digitizare#saveParcel"], [data-action*="digitizare#saveBuilding"]')
      .forEach(btn => {
        btn.disabled = !ok
        btn.title = ok ? "" : "Poligon invalid topologic — nu se poate salva"
      })
  }

  _updateDiffDisplay() {
    const act  = parseFloat(this.areaActTarget.value)
    const calc = this._areaCalc
    if (!act || !calc) { this.areaDiffTarget.textContent = "—"; this.areaDiffTarget.className = "digi-area-diff"; return }
    const pct  = ((calc - act) / act) * 100
    const sign = pct >= 0 ? "▲ +" : "▼ "
    this.areaDiffTarget.textContent = `${sign}${Math.abs(pct).toFixed(2)}%`
    this.areaDiffTarget.className   = `digi-area-diff ${Math.abs(pct) <= 3 ? "diff-ok" : Math.abs(pct) <= 10 ? "diff-warn" : "diff-bad"}`
  }

  // ── TXT import parsing ───────────────────────────────────────────────────

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
    // 6 decimale = precizie µm în metri Stereo70 — elimină drift-ul de
    // rotunjire care cauza overlap micrometric la poligoane adiacente.
    const ring = pts.map(v => `${v.x.toFixed(6)} ${v.y.toFixed(6)}`).join(", ")
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
      </style></head><body>
      <h1>Raport Digitizare Parcelă Cadastrală</h1>
      <p>Generat: ${new Date().toLocaleString("ro-RO")} | Proiecție: Stereo 70 (EPSG:3844)</p>
      <h2>Coordonate vertecși</h2>
      <table><thead><tr><th>#</th><th>X — Est (m)</th><th>Y — Nord (m)</th></tr></thead><tbody>${rows}</tbody></table>
      <h2>Suprafețe</h2>
      <p>Calculată (PostGIS): <b>${FMT2(calc)} mp</b> | Din act: <b>${act ? FMT2(act) + " mp" : "—"}</b> | Diferență: <b>${pct !== "—" ? (parseFloat(pct) >= 0 ? "+" : "") + pct + "%" : "—"}</b></p>
      <h2>WKT (Stereo 70)</h2>
      <pre style="font-size:10px;background:#f8fafc;padding:10px;overflow:auto;word-break:break-all">${this._buildWkt()}</pre>
    </body></html>`
  }

  // ── Keyboard shortcuts ───────────────────────────────────────────────────

  _handleGlobalKey(evt) {
    const tag = evt.target.tagName
    if (tag === "INPUT" || tag === "TEXTAREA") return
    if (evt.key === "F3") { evt.preventDefault(); this.toggleSnap() }
    if (evt.key === "F8") { evt.preventDefault(); this.toggleOrtho() }
    if (evt.key === "Escape" && this._draw) { evt.preventDefault(); this.clearAll() }
  }

  // ── Export zonă (DXF / KML / GPKG cu selecție dreptunghi sau poligon) ─

  startExportZoneSelect(evt) {
    if (!this.map) return
    const shape = evt?.params?.shape || "rect"
    // Curățăm orice zonă anterioară
    this.clearExportZone()
    // Dacă există o digitizare/edit activă, evităm conflict
    if (this._draw || this._editing) {
      this._setStatus("Termină digitizarea/editarea înainte de selecția zonei de export.", "warn")
      return
    }
    if (!this._exportZoneSource) {
      this._exportZoneSource = new ol.source.Vector()
      this._exportZoneLayer = new ol.layer.Vector({
        source: this._exportZoneSource,
        style: new ol.style.Style({
          stroke: new ol.style.Stroke({ color: "#16a34a", width: 2, lineDash: [6, 4] }),
          fill:   new ol.style.Fill({ color: "rgba(34, 197, 94, 0.10)" })
        }),
        zIndex: 950
      })
      this.map.addLayer(this._exportZoneLayer)
    }
    const drawOpts = { source: this._exportZoneSource }
    if (shape === "polygon") {
      drawOpts.type = "Polygon"
    } else {
      drawOpts.type = "Circle"
      drawOpts.geometryFunction = ol.interaction.Draw.createBox()
    }
    this._exportDraw = new ol.interaction.Draw(drawOpts)
    this.map.addInteraction(this._exportDraw)
    this._exportDraw.on("drawend", (e) => {
      this.map.removeInteraction(this._exportDraw)
      this._exportDraw = null
      this._exportZoneFeature = e.feature
      this._updateExportStatus()
    })
    if (this.hasExportStatusTarget) {
      this.exportStatusTarget.textContent = (shape === "polygon")
        ? "Click pentru fiecare vertex, dublu-click pentru a închide poligonul…"
        : "Click + drag pe hartă pentru a desena dreptunghiul…"
    }
  }

  clearExportZone() {
    if (this._exportDraw && this.map) { this.map.removeInteraction(this._exportDraw); this._exportDraw = null }
    this._exportZoneSource?.clear()
    this._exportZoneFeature = null
    this._updateExportStatus()
  }

  _updateExportStatus() {
    const has = !!this._exportZoneFeature
    if (this.hasBtnExportZoneSubmitTarget) this.btnExportZoneSubmitTarget.disabled = !has
    if (!this.hasExportStatusTarget) return
    if (!has) {
      this.exportStatusTarget.textContent = "Niciuna zonă selectată"
      return
    }
    const geom  = this._exportZoneFeature.getGeometry()
    const ring  = geom.getCoordinates()[0]
    const nVtx  = ring ? Math.max(0, ring.length - 1) : 0
    const area  = Math.round(geom.getArea())
    const isRect = nVtx === 4 && this._isRectangle(ring)
    const ext   = geom.getExtent()
    const w     = Math.round(ext[2] - ext[0])
    const h     = Math.round(ext[3] - ext[1])
    this.exportStatusTarget.textContent = isRect
      ? `Zonă (dreptunghi): ${w} × ${h} m, ${area} mp`
      : `Zonă (poligon): ${nVtx} vertecși, ${area} mp`
  }

  _isRectangle(ring) {
    if (!ring || ring.length !== 5) return false
    const [a, b, c, d] = ring
    return Math.abs(a[0] - d[0]) < 0.001 && Math.abs(a[1] - b[1]) < 0.001 &&
           Math.abs(b[0] - c[0]) < 0.001 && Math.abs(c[1] - d[1]) < 0.001
  }

  async exportZone(evt) {
    if (!this._exportZoneFeature) {
      this._setStatus("Selectează mai întâi o zonă cu butonul „Selectează zonă pe hartă\".", "warn")
      return
    }
    const url    = evt.params?.url || "/digitizare/export_zone"
    const format = this.hasExportFormatTarget ? this.exportFormatTarget.value : "dxf"
    const layers = []
    if (this.hasExportLayerParceleTarget && this.exportLayerParceleTarget.checked) layers.push("parcele")
    if (this.hasExportLayerCladiriTarget && this.exportLayerCladiriTarget.checked) layers.push("cladiri")
    if (layers.length === 0) { alert("Selectează cel puțin un layer (Parcele sau Clădiri)."); return }

    // WKT al dreptunghiului în Stereo70 (view nativ)
    const ring = this._exportZoneFeature.getGeometry().getCoordinates()[0]
    const wkt  = `POLYGON((${ring.map(c => `${c[0].toFixed(4)} ${c[1].toFixed(4)}`).join(", ")}))`

    const formData = new FormData()
    formData.append("authenticity_token", this._csrf())
    formData.append("area_wkt", wkt)
    formData.append("format", format)
    layers.forEach(l => formData.append("layers[]", l))

    if (this.hasExportStatusTarget) this.exportStatusTarget.textContent = "⏳ Se generează fișierul…"
    try {
      const res = await fetch(url, { method: "POST", body: formData })
      if (!res.ok) {
        const text = await res.text()
        if (this.hasExportStatusTarget) this.exportStatusTarget.textContent = `Eroare ${res.status}: ${text.slice(0, 100)}`
        return
      }
      const blob = await res.blob()
      const dl   = URL.createObjectURL(blob)
      const a    = Object.assign(document.createElement("a"), {
        href: dl,
        download: `export.${format}`
      })
      a.click()
      URL.revokeObjectURL(dl)
      if (this.hasExportStatusTarget) this.exportStatusTarget.textContent = `✓ Export ${format.toUpperCase()} finalizat`
    } catch (e) {
      if (this.hasExportStatusTarget) this.exportStatusTarget.textContent = `Eroare rețea: ${e.message}`
    }
  }

  // ── Import DXF ────────────────────────────────────────────────────────

  async onDxfFileSelected(evt) {
    const file = evt.target.files[0]
    if (!file) return
    const importUrl = evt.params?.url      || "/digitizare/import_dxf"
    const parseUrl  = evt.params?.parseUrl || "/digitizare/parse_geo_file"
    const ext = (file.name.split(".").pop() || "").toLowerCase()

    try {
      let layers = null
      if (ext === "dxf" && typeof DxfParser !== "undefined") {
        // DXF parsat în client (mai rapid, fără upload).
        const text = await file.text()
        layers = this._extractDxfPolygons(new DxfParser().parseSync(text))
      } else {
        // KML / GPKG / DXF (fallback) — parsare server-side prin GDAL.
        layers = await this._parseGeoFileServer(file, parseUrl)
      }

      if (!layers || Object.keys(layers).length === 0) {
        this._renderDxfMapping(null, "Niciun poligon închis găsit în fișier.")
        return
      }
      this._dxfLayers    = layers
      this._dxfImportUrl = importUrl
      this._renderDxfMapping(layers, file.name)
    } catch (e) {
      this._renderDxfMapping(null, `Eroare parsare fișier: ${e.message}`)
    } finally {
      evt.target.value = ""  // reset ca user să poată reîncărca același fișier
    }
  }

  async _parseGeoFileServer(file, url) {
    const fd = new FormData()
    fd.append("authenticity_token", this._csrf())
    fd.append("file", file)
    const res = await fetch(url, { method: "POST", body: fd, headers: { "Accept": "application/json" } })
    const data = await res.json()
    if (!data.ok) throw new Error(data.error || "parsare eșuată")
    return data.layers
  }

  _extractDxfPolygons(dxf) {
    const out = {}
    if (!dxf?.entities) return out
    dxf.entities.forEach(ent => {
      // LWPOLYLINE și POLYLINE pot fi închise (shape=true) sau deschise.
      // Pentru import, considerăm doar poligoanele închise.
      if (ent.type !== "LWPOLYLINE" && ent.type !== "POLYLINE") return
      const isClosed = ent.shape === true || ent.closed === true
      if (!isClosed) return
      const verts = (ent.vertices || []).filter(v => Number.isFinite(v.x) && Number.isFinite(v.y))
      if (verts.length < 3) return

      const layer = ent.layer || "0"
      if (!out[layer]) out[layer] = []
      out[layer].push(verts.map(v => [v.x, v.y]))
    })
    return out
  }

  _renderDxfMapping(layers, filenameOrError) {
    if (!this.hasDxfMappingTarget) return
    const root = this.dxfMappingTarget

    if (!layers) {
      root.style.display = "block"
      root.innerHTML = `<div class="topo-warn">${filenameOrError}</div>`
      return
    }

    // Alegere automată default mapping bazat pe nume layer
    const guess = (layerName) => {
      const n = layerName.toUpperCase()
      if (/PARC|TEREN|IMOBIL|LIM/.test(n))   return "parcela"
      if (/CLAD|CONST|BUILD/.test(n))         return "cladire"
      if (/SECT/.test(n))                     return "sector"
      return "ignora"
    }

    const rows = Object.entries(layers).map(([layer, polys]) => {
      const def = guess(layer)
      const opts = ["parcela", "cladire", "sector", "ignora"].map(c => {
        const labels = { parcela: "Parcele", cladire: "Clădiri", sector: "Sectoare", ignora: "Ignoră" }
        return `<option value="${c}" ${c === def ? "selected" : ""}>${labels[c]}</option>`
      }).join("")
      return `
        <tr>
          <td>${layer}</td>
          <td style="text-align:right">${polys.length}</td>
          <td>
            <select class="input input-sm dxf-cat" data-layer="${layer}">${opts}</select>
          </td>
        </tr>
      `
    }).join("")

    root.style.display = "block"
    root.innerHTML = `
      <div class="digi-dxf-header">📥 ${filenameOrError}</div>
      <table class="digi-dxf-table">
        <thead><tr><th>Layer DXF</th><th>Poligoane</th><th>Mapează la</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
      <div class="digi-dxf-defaults">
        <div class="digi-section-label" style="margin:8px 0 4px">Defaults pentru parcele</div>
        <div class="digi-save-grid">
          <select class="input input-sm" data-digitizare-target="dxfCategFolosinta">
            <option value="neproductiv" selected>Neproductiv</option>
            <option value="arabil">Arabil</option>
            <option value="pasune">Pășune</option>
            <option value="faneata">Fânețe</option>
            <option value="vie">Vie</option>
            <option value="livada">Livadă</option>
            <option value="padure">Pădure</option>
            <option value="curti_constructii">Curți/construcții</option>
            <option value="ape">Ape</option>
          </select>
          <input type="text" class="input input-sm" placeholder="Județ" data-digitizare-target="dxfJudet">
          <input type="text" class="input input-sm" placeholder="Localitate" data-digitizare-target="dxfLocalitate">
        </div>
      </div>
      <div class="digi-btn-row" style="margin-top:8px">
        <button type="button" class="btn btn-primary btn-sm" data-action="click->digitizare#submitDxfImport">
          ✓ Importă
        </button>
        <button type="button" class="btn btn-outline btn-sm" data-action="click->digitizare#cancelDxfImport">
          ✕ Anulează
        </button>
      </div>
      <div class="digi-dxf-result" data-digitizare-target="dxfResult"></div>
    `
  }

  cancelDxfImport() {
    if (!this.hasDxfMappingTarget) return
    this.dxfMappingTarget.style.display = "none"
    this.dxfMappingTarget.innerHTML = ""
    this._dxfLayers = null
  }

  async submitDxfImport() {
    if (!this._dxfLayers) return
    const items = []
    this.dxfMappingTarget.querySelectorAll(".dxf-cat").forEach(sel => {
      const layer = sel.dataset.layer
      const cat   = sel.value
      if (cat === "ignora") return
      const polys = this._dxfLayers[layer] || []
      polys.forEach((coords, idx) => {
        const wkt = this._coordsToWkt(coords)
        if (wkt) items.push({ category: cat, geom_wkt: wkt, source_layer: layer, source_idx: idx })
      })
    })
    if (items.length === 0) {
      alert("Niciun poligon nu e mapat la o categorie (toate sunt ignorate).")
      return
    }

    const defaults = {
      categoria_folosinta: this.element.querySelector('[data-digitizare-target="dxfCategFolosinta"]')?.value,
      judet:               this.element.querySelector('[data-digitizare-target="dxfJudet"]')?.value || "—",
      localitate:          this.element.querySelector('[data-digitizare-target="dxfLocalitate"]')?.value || "—"
    }

    const resultEl = this.element.querySelector('[data-digitizare-target="dxfResult"]')
    if (resultEl) resultEl.innerHTML = "⏳ Se importă..."

    try {
      const res = await fetch(this._dxfImportUrl || "/digitizare/import_dxf", {
        method:  "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this._csrf(),
          "Accept":       "application/json"
        },
        body: JSON.stringify({ items, defaults })
      })
      const data = await res.json()
      if (data.ok) {
        const r = data.results
        const msg = `✓ ${r.parcela.created} parcele + ${r.cladire.created} clădiri create`
                  + (r.parcela.errors.length || r.cladire.errors.length ? " (cu erori — vezi detalii)" : "")
        if (resultEl) {
          resultEl.innerHTML = `
            <div class="topo-ok">${msg}</div>
            ${r.parcela.errors.length ? `<div class="topo-warn"><b>Erori parcele:</b><br>${r.parcela.errors.join('<br>')}</div>` : ""}
            ${r.cladire.errors.length ? `<div class="topo-warn"><b>Erori clădiri:</b><br>${r.cladire.errors.join('<br>')}</div>` : ""}
          `
        }
        // Reload parcele și clădiri pe hartă
        this._hartaMap?._loadParcele()
        this._hartaMap?._loadCladiri()
      } else {
        if (resultEl) resultEl.innerHTML = `<div class="topo-warn">Eroare: ${data.error}</div>`
      }
    } catch (e) {
      if (resultEl) resultEl.innerHTML = `<div class="topo-warn">Eroare rețea: ${e.message}</div>`
    }
  }

  _coordsToWkt(coords) {
    if (!coords || coords.length < 3) return null
    const closed = (coords[0][0] !== coords[coords.length - 1][0] || coords[0][1] !== coords[coords.length - 1][1])
                   ? [...coords, coords[0]] : coords
    const ring = closed.map(c => `${c[0].toFixed(6)} ${c[1].toFixed(6)}`).join(", ")
    return `MULTIPOLYGON(((${ring})))`
  }

  // ── Audit topologie global ─────────────────────────────────────────────

  async runAuditTopologie(evt) {
    const url = evt?.params?.url || "/digitizare/audit_topologie"
    if (this.hasBtnAuditTarget) {
      this.btnAuditTarget.disabled = true
      this.btnAuditTarget.textContent = "🔄 Scanare…"
    }
    try {
      const res = await fetch(url, { headers: { "Accept": "application/json" } })
      const data = await res.json()
      this._renderAuditResults(data)
    } catch (e) {
      this._setStatus(`Eroare audit: ${e.message}`, "warn")
    } finally {
      if (this.hasBtnAuditTarget) {
        this.btnAuditTarget.disabled = false
        this.btnAuditTarget.textContent = "🔍 Scanează erori"
      }
    }
  }

  clearAudit() {
    this._auditSource?.clear()
    this._auditIssues       = []
    this._auditIssueExtents = []
    if (this.hasAuditListTarget) this.auditListTarget.innerHTML = ""
    if (this._auditMoveBound && this._auditMoveKey && this.map) {
      ol.Observable.unByKey(this._auditMoveKey)
      this._auditMoveKey   = null
      this._auditMoveBound = false
    }
  }

  // Apelat din onclick inline pe items din lista audit
  zoomToAuditIssue(idx) {
    const features = this._auditSource?.getFeatures() || []
    const feat = features[idx]
    if (!feat || !this.map) return
    const ext = feat.getGeometry().getExtent()
    this.map.getView().fit(ext, { padding: [80, 80, 80, 80], maxZoom: 19, duration: 350 })
  }

  _renderAuditResults(data) {
    this._auditSource.clear()
    this._auditIssues       = []   // [{ ...issue, _idx }, ...]
    this._auditIssueExtents = []   // [extent, ...] aliniat cu _auditIssues
    if (!this.hasAuditListTarget) return
    if (!data.issues || data.issues.length === 0) {
      this.auditListTarget.innerHTML = `<div class="topo-ok">✓ Niciuna erori topologice (${data.total || 0} verificate)</div>`
      return
    }

    // Adaugă features în source + cache la extent pentru filtrare pe viewport
    const fmt = new ol.format.GeoJSON()
    data.issues.forEach((issue, idx) => {
      this._auditIssues.push({ ...issue, _idx: idx })
      if (!issue.geojson) { this._auditIssueExtents.push(null); return }
      try {
        const feat = fmt.readFeature(issue.geojson, {
          dataProjection:    "EPSG:3844",
          featureProjection: "EPSG:3844"
        })
        feat.set("severity", issue.severity)
        feat.set("auditIdx",  idx)
        this._auditSource.addFeature(feat)
        this._auditIssueExtents.push(feat.getGeometry().getExtent())
      } catch (e) {
        this._auditIssueExtents.push(null)
      }
    })

    // Listener pentru zoom-pe-item (delegated)
    if (!this._auditZoomBound) {
      this.element.addEventListener("audit-zoom", (e) => this.zoomToAuditIssue(e.detail))
      this._auditZoomBound = true
    }

    // Listener pentru filtrare dinamică la pan/zoom
    if (!this._auditMoveBound && this.map) {
      this._auditMoveKey = this.map.on("moveend", () => this._filterAndRenderAuditByViewport())
      this._auditMoveBound = true
    }

    this._filterAndRenderAuditByViewport()
  }

  _filterAndRenderAuditByViewport() {
    if (!this.hasAuditListTarget) return
    if (!this._auditIssues || this._auditIssues.length === 0) return

    const all = this._auditIssues
    let visible
    if (this.map) {
      const vp = this.map.getView().calculateExtent(this.map.getSize())
      visible = all.filter((iss) => {
        const ext = this._auditIssueExtents[iss._idx]
        return ext && ol.extent.intersects(vp, ext)
      })
    } else {
      visible = all.slice()
    }
    this._renderAuditList(visible, all.length)
  }

  _renderAuditList(items, totalCount) {
    if (!this.hasAuditListTarget) return
    if (items.length === 0) {
      this.auditListTarget.innerHTML = `
        <div class="digi-audit-summary">
          <strong>0 probleme în viewport</strong> (din ${totalCount} total)
          <div style="font-size:11px;color:#6b7280">Dă zoom-out sau pan pentru a vedea alte erori.</div>
        </div>
      `
      return
    }

    const byCat = {}
    items.forEach((iss) => {
      const cat = iss.category || "Altele"
      if (!byCat[cat]) byCat[cat] = []
      byCat[cat].push(iss)
    })

    const sections = Object.entries(byCat).map(([cat, list]) => {
      const itemsHtml = list.map(i => `
        <li class="digi-audit-item digi-audit-item--${i.severity || 'error'}">
          <button type="button" class="digi-audit-zoom-btn"
                  onclick="event.stopPropagation();
                           document.querySelector('[data-controller~=digitizare]').dispatchEvent(
                             new CustomEvent('audit-zoom', { detail: ${i._idx} }))">
            🔎
          </button>
          <span>${i.message}</span>
        </li>
      `).join("")
      return `
        <div class="digi-audit-category">
          <div class="digi-audit-category-header">${cat} <span class="badge badge-error">${list.length}</span></div>
          <ul class="digi-audit-items">${itemsHtml}</ul>
        </div>
      `
    }).join("")

    const filterHint = items.length < totalCount
      ? `<span style="font-size:11px;color:#6b7280">(${totalCount - items.length} ascunse — în afara viewport)</span>`
      : ""
    this.auditListTarget.innerHTML = `
      <div class="digi-audit-summary">
        <strong>${items.length} probleme vizibile</strong> ${filterHint}
      </div>
      ${sections}
    `
  }

  // ── Selecție feature (pentru intrare în edit mode) ────────────────────────

  _onFeatureSelected(sel) {
    if (this._draw || this._editing) return
    this._selected = sel
    this._updateEditButton()
    this._updateToolbarVisibility?.()
    this._populateAreaFromSelection(sel)
    this._populateFormFromSelection(sel)
  }

  // Populare câmpuri formular Parcelă/Clădire la selecția unui poligon —
  // sincron din proprietățile GeoJSON (cadgenno, suprafață, categorie), apoi
  // async via `/lands/:id/popup_info.json` pentru proprietari + adresă.
  _populateFormFromSelection(sel) {
    if (!sel) {
      this._clearSelectionForm()
      return
    }
    const f         = sel.feature
    const isCladire = sel.kind === "cladire"

    // Arătăm formularul potrivit (parcelă vs clădire)
    if (this.hasFormParcelaTarget) this.formParcelaTarget.style.display = isCladire ? "none" : ""
    if (this.hasFormCladireTarget) this.formCladireTarget.style.display = isCladire ? ""    : "none"
    const formRoot = isCladire ? this.formCladireTarget : this.formParcelaTarget
    if (!formRoot) return

    const setVal = (suffix, value) => {
      const input = formRoot.querySelector(`[name$="${suffix}]"]`)
      if (input != null && value != null && value !== "") input.value = value
    }

    // Sync — din GeoJSON props (suport pentru cgxml + parcele/cladiri layer)
    setVal("numar_cadastral", f.get("cadgenno") || f.get("numar_cadastral") || "")
    const calcArea = f.get("measuredarea") || f.get("suprafata_mp")
    if (!isCladire) {
      setVal("categoria_folosinta", f.get("categoria_folosinta") || "")
      setVal("suprafata_mp",        calcArea ? Number(calcArea).toFixed(2) : "")
    } else {
      setVal("destinatie",                f.get("buildingdestination") || "")
      const lv = f.get("levelsno")
      setVal("regim_inaltime",            lv ? `P+${Math.max(0, Number(lv) - 1)}` : "")
      setVal("suprafata_construita_mp",   calcArea ? Number(calcArea).toFixed(2) : "")
    }

    // Async — owners + address din popup_info
    const id  = f.get("id")
    const url = isCladire ? `/buildings/${id}/popup_info.json` : `/lands/${id}/popup_info.json`
    fetch(url, { headers: { Accept: "application/json" } })
      .then(r => r.ok ? r.json() : null)
      .then(data => {
        if (!data) return
        // Verifică că selecția curentă e încă același feature
        if (this._selected?.feature !== f) return
        if (!isCladire && data.categoria_folosinta) {
          setVal("categoria_folosinta", data.categoria_folosinta)
        }
        if (isCladire && data.destinatie) setVal("destinatie", data.destinatie)
        if (data.address) {
          setVal("judet",      data.address.judet || "")
          setVal("localitate", data.address.localitate || "")
        }
        const owners = (data.owners || [])
          .filter(o => o && (o.lastname || o.firstname))
          .map(o => [o.lastname, o.fatherinitial, o.firstname].filter(Boolean).join(" "))
        if (owners.length) setVal("proprietar", owners.join("; "))
      })
      .catch(() => { /* no-op */ })
  }

  // Curăță inputurile din formularele Parcelă/Clădire la deselecție.
  _clearSelectionForm() {
    [this.hasFormParcelaTarget && this.formParcelaTarget,
     this.hasFormCladireTarget && this.formCladireTarget].filter(Boolean).forEach(form => {
      form.querySelectorAll("input[type=text], input[type=number]").forEach(i => i.value = "")
      form.querySelectorAll("select").forEach(s => s.selectedIndex = 0)
    })
  }

  // Populare câmpuri Suprafață (Calculată / Din act / Diferență) la simpla
  // selecție a unui poligon. Calculată: `measuredarea` (CGXML) sau
  // `suprafata_mp` (parcele/cladiri); Din act: `parcellegalarea` (CGXML).
  _populateAreaFromSelection(sel) {
    if (!sel) {
      this._areaCalc = 0
      if (this.hasAreaCalcTarget)   this.areaCalcTarget.textContent = "—"
      if (this.hasAreaActTarget)    this.areaActTarget.value = ""
      if (this.hasAreaDiffTarget)   { this.areaDiffTarget.textContent = "—"; this.areaDiffTarget.className = "digi-area-diff" }
      if (this.hasStatusAreaTarget) this.statusAreaTarget.textContent = "—"
      return
    }
    const f = sel.feature
    let calc = Number(f.get("measuredarea") ?? f.get("suprafata_mp"))
    if (!Number.isFinite(calc) || calc <= 0) {
      const g = f.getGeometry?.()
      if (g?.getArea) calc = g.getArea()
    }
    this._areaCalc = Number.isFinite(calc) && calc > 0 ? calc : 0
    if (this.hasAreaCalcTarget) {
      this.areaCalcTarget.textContent = this._areaCalc > 0 ? `${FMT2(this._areaCalc)} mp` : "—"
    }
    // Bara de status de jos arată ACUM suprafața feature-ului selectat
    // (chiar dacă nu suntem în mod draw/edit). În draw/edit, `_updateLiveArea`
    // o suprascrie cu valoarea calculată din _verts.
    if (this.hasStatusAreaTarget) {
      this.statusAreaTarget.textContent = this._areaCalc > 0 ? `${FMT2(this._areaCalc)} mp` : "—"
    }
    const act = Number(f.get("parcellegalarea"))
    if (this.hasAreaActTarget) this.areaActTarget.value = act > 0 ? act.toFixed(2) : ""
    this._updateDiffDisplay()
  }

  _updateEditButton() {
    const sel = this._selected
    if (this.hasBtnEditTarget) {
      this.btnEditTarget.disabled = !sel
      // Actualizăm DOAR title (tooltip); textContent ar suprascrie SVG-ul.
      if (sel) {
        const label = sel.feature.get("numar_cadastral") || `#${sel.feature.get("id")}`
        this.btnEditTarget.title = `Editează ${sel.kind} ${label} (comandă: M)`
      } else {
        this.btnEditTarget.title = "Modifică vertecșii poligonului selectat (comandă: M)"
      }
    }
    if (this.hasBtnDeleteTarget) {
      this.btnDeleteTarget.disabled = !sel
      if (sel) {
        const label = sel.feature.get("numar_cadastral") || `#${sel.feature.get("id")}`
        this.btnDeleteTarget.title = `Șterge ${sel.kind} ${label}`
      } else {
        this.btnDeleteTarget.title = "Click pe un poligon de pe hartă pentru a-l selecta"
      }
    }
    if (this.hasBtnMoveTarget) {
      this.btnMoveTarget.disabled = !sel
      if (sel) {
        const label = sel.feature.get("numar_cadastral") || `#${sel.feature.get("id")}`
        this.btnMoveTarget.title = `Mută ${sel.kind} ${label} — drag pe geometrie, SV salvează`
      } else {
        this.btnMoveTarget.title = "Click pe un poligon de pe hartă pentru a-l selecta"
      }
    }
    if (this.hasBtnRotateTarget) {
      this.btnRotateTarget.disabled = !sel
      if (sel) {
        const label = sel.feature.get("numar_cadastral") || `#${sel.feature.get("id")}`
        this.btnRotateTarget.title = `Rotește ${sel.kind} ${label} — click pivot pe un vertex, apoi mișcă cursor-ul`
      } else {
        this.btnRotateTarget.title = "Click pe un poligon de pe hartă pentru a-l selecta"
      }
    }
  }

  // Acțiune publică pentru butonul „Mută" din sidebar — proxy la `_startMove`
  // (single) sau `_startBulkMove` (multi-select).
  moveSelected() {
    const multi = this._hartaMap?.getMultiSelection?.() || []
    if (multi.length >= 1 && this._multiSelectActive) {
      this._startBulkMove(multi)
      return
    }
    this._startMove()
  }

  // Acțiune publică pentru butonul „Rotește" — single sau bulk în funcție de
  // selecția multiplă activă.
  rotateSelected() {
    const multi = this._hartaMap?.getMultiSelection?.() || []
    if (multi.length >= 1 && this._multiSelectActive) {
      this._startBulkRotate(multi)
      return
    }
    this._startRotate()
  }

  // ── Mutare bloc (multi-select) ────────────────────────────────────────────
  // Același flow ca single-move (click vertex bază → click destinație), dar
  // aplicat pe TOATE poligoanele din selecția multiplă (parcele + clădiri).
  // CHAIN: dacă există deja un _bulkOp (de la o operațiune anterioară), această
  // mutare se aplică PESTE rezultatul ei (geometria curentă = punct de plecare),
  // iar `baseline` original se păstrează pentru Cancel global.
  _startBulkMove(items) {
    const chain = this._isBulkChainable()
    if (this._postDrawTransform && !chain) this._cancelTransform()
    // La chain: dezactivăm Modify-ul de vertex-editing din operațiunea anterioară
    // (se reactivează după commit-ul mutării curente).
    if (this._bulkModify && this.map) {
      this.map.removeInteraction(this._bulkModify)
      this._bulkModify = null
    }
    this._snapIncludeBulkItems = false

    const preparedItems = chain
      ? this._bulkOp.items.map(it => ({
          ...it,
          // baseline + baselineCoords păstrate (= original pre-chain, pentru Cancel)
        }))
      : items.map(it => {
          const baseline = it.feature.getGeometry().clone()
          return {
            kind:           it.kind,
            feature:        it.feature,
            layer:          it.layer,
            baseline,
            baselineCoords: baseline.getCoordinates()
          }
        })
    this._renderBulkVertices(preparedItems)
    this._cmdHint(`Mutare bloc: ${preparedItems.length} poligoane${chain ? " (chain)" : ""}.`, false)
    this._beginMoveByPoints(preparedItems, "bulk-move")
  }

  // Returnează true dacă există un _bulkOp post-commit (cu items) peste care
  // poate fi înlănțuită o operațiune nouă (Mută sau Rotește). Operațiunile
  // active (preview neîncheiat) nu se înlănțuiesc — utilizatorul ar trebui să
  // commit-uie sau anuleze prima.
  _isBulkChainable() {
    if (!this._bulkOp?.items?.length) return false
    // _moveOp / _rotateMoveKey active = operațiune în PREVIEW → nu chain
    if (this._moveOp) return false
    if (this._rotateMoveKey || this._rotateClickKey) return false
    return true
  }

  // Render TOȚI vertecșii featurilor din selecție bulk în `_editVertexSource`.
  // OL Snap include automat acești vertecși ca ținte → primul click prinde
  // exact pe vertex. Curățarea se face la _endBulkOp / _cancelTransform.
  //
  // În plus, randăm vertecșii TUTUROR poligoanelor din viewport ca ținte
  // VIZUALE de destinație (cu stilul neighborVertex — cerculețe portocalii).
  // Astfel utilizatorul vede CLAR unde poate snap-ui la click 2.
  _renderBulkVertices(items) {
    if (!this._editVertexSource) return
    const selectedSet = new Set(items.map(it => it.feature))
    items.forEach(it => {
      this._addAllVertexesAsPoints(it.feature, this._editVertexSource, false)
    })
    this._renderDestinationVertices(selectedSet)
    // Refresh snap features ca să includă noua sursă de vertecși.
    this._refreshSnap()
  }

  // Randează vertecșii TUTUROR poligoanelor din viewport (parcele + clădiri +
  // cgxml), exceptând cele din `excludeSet` (selecția curentă de mutat/rotit).
  // Cerculețele portocalii = ținte de snap vizibile la destinație.
  _renderDestinationVertices(excludeSet) {
    if (!this._editVertexSource || !this._hartaMap) return
    const view = this.map.getView()
    const extent = view.calculateExtent(this.map.getSize())
    const layers = [
      this._hartaMap.parcelLayer,
      this._hartaMap.cladiriLayer,
      this._hartaMap.cgxmlLayer
    ].filter(Boolean)
    layers.forEach(layer => {
      const src = layer.getSource()
      if (!src) return
      src.forEachFeatureInExtent(extent, (f) => {
        if (excludeSet?.has(f)) return
        this._addAllVertexesAsPoints(f, this._editVertexSource, true)
      })
    })
  }

  // ── Rotație bloc (multi-select) ───────────────────────────────────────────
  // Pivot la un click pe hartă (snap pe cel mai apropiat vertex al oricărui
  // poligon selectat). Mouse-move = preview rotație live pe toate poligoanele
  // din selecție. Click 2 = commit; A = restaurare.
  _startBulkRotate(items) {
    const chain = this._isBulkChainable()
    if (this._postDrawTransform && !chain) this._cancelTransform()
    // Dezactivăm Modify de vertex-editing din operațiunea anterioară.
    if (this._bulkModify && this.map) {
      this.map.removeInteraction(this._bulkModify)
      this._bulkModify = null
    }
    this._snapIncludeBulkItems = false

    const bulkItems = chain
      ? this._bulkOp.items.map(it => ({
          ...it,
          // Snapshot la START rotație — preview-ul rotește din această stare.
          // ORIGINAL baseline + baselineCoords păstrate pentru Cancel.
          previewBaseline: it.feature.getGeometry().clone()
        }))
      : items.map(it => {
          const baseline = it.feature.getGeometry().clone()
          return {
            kind:            it.kind,
            feature:         it.feature,
            layer:           it.layer,
            baseline:        baseline,
            baselineCoords:  baseline.getCoordinates(),
            previewBaseline: baseline.clone()
          }
        })

    this._bulkOp = {
      type:       "rotate",
      items:      bulkItems,
      pivot:      null,
      startAngle: null
    }
    this._postDrawTransform = "bulk-rotate"
    // Randăm vertecșii bulk + refresh snap pentru pivot-snap.
    this._renderBulkVertices(this._bulkOp.items)
    this._cmdHint(`Rotație bloc: ${bulkItems.length} poligoane${chain ? " (chain)" : ""}. Click pe orice vertex pentru pivot.`, false)
    this._rotateClickKey = this.map.on("singleclick", (evt) => {
      if (!this._bulkOp.pivot) {
        // Click 1: snap pe cel mai apropiat vertex al oricărui feature selectat.
        // Folosim previewBaseline (snapshot la start rotație) — la chain, baseline
        // e ORIGINAL pre-chain și nu reflectă poziția curentă.
        const click = evt.coordinate
        let bestDist = Infinity
        let bestVert = null
        this._bulkOp.items.forEach(it => {
          const geom = it.previewBaseline || it.baseline
          const t = geom.getType()
          const rings = t === "Polygon" ? geom.getCoordinates()
                      : t === "MultiPolygon" ? geom.getCoordinates().flat()
                      : []
          rings.forEach(ring => {
            const verts = ring.length > 1 ? ring.slice(0, -1) : ring
            verts.forEach(c => {
              const d = Math.hypot(c[0] - click[0], c[1] - click[1])
              if (d < bestDist) { bestDist = d; bestVert = [c[0], c[1]] }
            })
          })
        })
        if (!bestVert) {
          this._cmdHint("Niciun vertex disponibil.", true)
          return
        }
        this._bulkOp.pivot = bestVert
        this._renderRotatePivotMarker(bestVert)
        this._cmdHint("Mișcă cursor-ul pentru rotație · click confirmă.", false)
        this._rotateMoveKey = this.map.on("pointermove", (mEvt) => {
          const cur = mEvt.coordinate
          const a = Math.atan2(cur[1] - bestVert[1], cur[0] - bestVert[0])
          if (this._bulkOp.startAngle === null) { this._bulkOp.startAngle = a; return }
          const delta = a - this._bulkOp.startAngle
          this._bulkOp.items.forEach(it => {
            // Rotim din previewBaseline = snapshot la start-ul ACESTEI rotații
            // (NU din baseline care e ORIGINAL pre-chain).
            const src = it.previewBaseline || it.baseline
            const rotated = src.clone()
            rotated.rotate(delta, bestVert)
            // setCoordinates → păstrăm instanța (consistent cu single-rotate).
            it.feature.getGeometry().setCoordinates(rotated.getCoordinates())
          })
          this._hartaMap?._refreshMultiSelectOverlay?.()
        })
        return
      }
      // Click 2: commit
      if (this._bulkOp.startAngle === null) return
      if (this._rotateMoveKey)  { ol.Observable.unByKey(this._rotateMoveKey);  this._rotateMoveKey = null }
      if (this._rotateClickKey) { ol.Observable.unByKey(this._rotateClickKey); this._rotateClickKey = null }
      this._removeRotatePivotMarker()
      // Activăm editarea de vertecși pe items după commit (același flow ca move).
      this._enableBulkVertexEditing(this._bulkOp.items)
      this._injectBulkControls("Rotație bloc", this._bulkOp.items.length, [
        `Rotație aplicată pe ${this._bulkOp.items.length} poligoane.`,
        "<b>Drag pe orice vertex</b> pentru ajustare topologie.",
        "Save validează topologia înainte de persistare."
      ])
      this._cmdHint("✓ Rotație aplicată. Drag vertex pentru ajustări sau Save.", false)
    })
  }

  // ── Save / Cancel bloc ────────────────────────────────────────────────────
  saveBulk()   { this._saveBulk() }
  cancelBulk() { this._cancelBulk() }

  async _saveBulk() {
    if (!this._bulkOp || this._bulkOp.items.length === 0) return
    const items = this._bulkOp.items

    // 1) Validare topologică PRE-SAVE pe fiecare feature din bloc.
    //    Exclude_neighbor_ids = restul featurilor din bloc → nu se penalizează
    //    intersecțiile relative dintre ele (se mișcă împreună, deci nu pot
    //    genera overlap-uri reciproce nesoluționabile).
    if (!await this._validateBulkBeforeSave(items)) return

    const buildPayload = (it) => ({
      kind: it.kind,
      id:   String(it.feature.get("id")),
      geom_wkt: this._buildWktFromGeom(it.feature.getGeometry()),
      suprafata_mp: null
    })
    const primary   = buildPayload(items[0])
    const neighbors = items.slice(1).map(buildPayload)
    this._setStatus(`Salvare bloc: ${items.length} poligoane…`, "info")
    try {
      const res  = await fetch(this.saveBatchUrlValue, {
        method:  "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf(), "Accept": "application/json" },
        body:    JSON.stringify({ primary, neighbors })
      })
      const data = await res.json()
      if (data.ok) {
        this._setStatus(`✓ ${items.length} poligoane salvate.`, "ok")
        this._endBulkOp(false)
        this._hartaMap?._loadParcele?.()
        this._hartaMap?._loadCladiri?.()
        this._hartaMap?._loadCgxml?.()
      } else {
        this._setStatus("Erori: " + (data.errors || []).join(" | "), "warn")
      }
    } catch (e) {
      this._setStatus(`Eroare rețea: ${e.message}`, "warn")
    }
  }

  // Validare topologică pentru fiecare feature din selecția bulk.
  // Returnează false dacă există conflicte hard (> 1 mp / non-fixable).
  // Pentru conflicte ≤ 1 mp afișează status warn dar nu blochează.
  async _validateBulkBeforeSave(items) {
    if (!this.hasVerificaUrlValue) return true
    const excludeAllIds = items.map(it => String(it.feature.get("id")))
    this._setStatus(`Verificare topologică: ${items.length} poligoane…`, "info")
    const allErrors = []
    for (const it of items) {
      const itemId = String(it.feature.get("id"))
      const coords = this._coordsFromGeom(it.feature.getGeometry())
      if (!coords || coords.length < 3) continue
      const params = {
        coords,
        entity_type: it.kind,
        exclude_id:  itemId,
        exclude_neighbor_ids: excludeAllIds.filter(id => id !== itemId)
      }
      try {
        const res  = await fetch(this.verificaUrlValue, {
          method:  "POST",
          headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrf() },
          body:    JSON.stringify(params)
        })
        const data = await res.json()
        if (data.has_errors) {
          const errs = (data.issues || []).filter(i => i.severity === "error")
          const hard = errs.filter(i => !i.fixable)
          if (hard.length > 0) {
            allErrors.push({ id: itemId, kind: it.kind, errors: hard })
          }
        }
      } catch (e) {
        console.warn("Bulk topology check error for", itemId, e)
      }
    }
    if (allErrors.length > 0) {
      const summary = allErrors.map(e => `${e.kind}#${e.id} (${e.errors.length} conflict[e])`).join(", ")
      this._setStatus(`⛔ Topologie eronată — nu se salvează: ${summary}. Anulează și ajustează manual.`, "warn")
      return false
    }
    return true
  }

  // Extrage [[x, y], …] din inelul exterior al unui Polygon OL.
  _coordsFromGeom(geom) {
    if (!geom || geom.getType() !== "Polygon") return null
    const ring = geom.getCoordinates()?.[0]
    if (!ring || ring.length < 4) return null
    return ring.slice(0, -1).map(([x, y]) => [x, y])
  }

  _cancelBulk() {
    if (!this._bulkOp) return
    this._bulkOp.items.forEach(it => {
      if (it.baselineCoords) {
        it.feature.getGeometry().setCoordinates(it.baselineCoords)
      } else if (it.baseline) {
        it.feature.setGeometry(it.baseline)
      }
    })
    this._endBulkOp(true)
  }

  _endBulkOp(restored) {
    if (this._translate && this.map) { this.map.removeInteraction(this._translate); this._translate = null }
    if (this._rotateMoveKey)  { ol.Observable.unByKey(this._rotateMoveKey);  this._rotateMoveKey = null }
    if (this._rotateClickKey) { ol.Observable.unByKey(this._rotateClickKey); this._rotateClickKey = null }
    this._removeRotatePivotMarker()
    this._removeBulkControls()
    if (this._bulkModify && this.map) {
      this.map.removeInteraction(this._bulkModify)
      this._bulkModify = null
    }
    this._snapIncludeBulkItems = false
    this._removeSnapHover()
    // Curățăm vertecșii bulk randați la _renderBulkVertices (păstrăm visualNeighbor).
    if (this._editVertexSource) {
      const keep = this._editVertexSource.getFeatures().filter(f => f.get("visualNeighbor"))
      this._editVertexSource.clear()
      keep.forEach(f => this._editVertexSource.addFeature(f))
    }
    this._bulkOp = null
    this._postDrawTransform = null
    this._hartaMap?._refreshMultiSelectOverlay?.()
    if (restored) this._setStatus("Operațiune bloc anulată.", "info")
  }

  _injectBulkControls(title, count, hints) {
    if (!this.hasPanelBodyTarget) return
    this.element.querySelector(".digi-bulk-controls")?.remove()
    const div = document.createElement("section")
    div.className = "digi-section digi-edit-panel digi-bulk-controls"
    const hintHtml = hints.map(h => `<li>${h}</li>`).join("")
    div.innerHTML = `
      <div class="digi-edit-header">${title} — ${count} poligoane</div>
      <ul class="digi-parcela-hint" style="margin:6px 0;padding-left:18px;line-height:1.6">${hintHtml}</ul>
      <button type="button" class="btn btn-primary btn-sm digi-ctx-btn"
              data-action="click->digitizare#saveBulk">${this._iconSave()} Salvează ${count} poligoane</button>
      <button type="button" class="btn btn-secondary btn-sm digi-ctx-btn"
              data-action="click->digitizare#cancelBulk">${this._iconCancel()} Anulează bloc</button>
    `
    this.panelBodyTarget.insertBefore(div, this.panelBodyTarget.firstChild)
  }

  _removeBulkControls() {
    this.element.querySelector(".digi-bulk-controls")?.remove()
  }

  async deleteSelected() {
    const sel = this._selected
    if (!sel) {
      this._setStatus("Selectează un poligon pe hartă (click pe el) înainte de Șterge.", "warn")
      return
    }
    const label = sel.feature.get("numar_cadastral") || `#${sel.feature.get("id")}`
    if (!confirm(`Ștergi ${sel.kind} ${label}?\n\nAceastă acțiune e ireversibilă.`)) return

    const url = sel.kind === "cladire"
      ? `/buildings/${sel.feature.get("id")}`
      : `/lands/${sel.feature.get("id")}`

    try {
      const res = await fetch(url, {
        method:  "DELETE",
        headers: {
          "X-CSRF-Token": this._csrf(),
          "Accept":       "application/json"
        }
      })
      if (res.ok) {
        this._setStatus(`${sel.kind} ${label} ștearsă.`, "ok")
        // Dacă suntem în edit mode pe feature-ul șters, ieșim curat (modify
        // interaction, panou edit, layer vertecsi/edges) — fără reload aici,
        // încărcăm layerele jos.
        if (this._editing) this._resetEditUIState()
        // Curăț selecția vizual + state + URL focus param (entitatea nu mai există)
        this._hartaMap?.clearSelection?.()
        this._hartaMap?._updateFocusUrlParams?.(null)
        this._selected = null
        this._updateEditButton()
    this._updateToolbarVisibility?.()
        // Reload toate layerele relevante (feature-ul poate fi în parcele
        // sau în cgxml — sau în cladiri/cgxml pentru clădiri).
        this._hartaMap?._loadParcele?.()
        this._hartaMap?._loadCladiri?.()
        this._hartaMap?._loadCgxml?.()
      } else {
        const data = await res.json().catch(() => ({}))
        this._setStatus(`Eroare la ștergere: ${data.error || res.status}`, "warn")
      }
    } catch (e) {
      this._setStatus(`Eroare rețea: ${e.message}`, "warn")
    }
  }

  // ── Selecție multiplă + ștergere în bloc ──────────────────────────────

  toggleMultiSelect() {
    if (!this._hartaMap) return
    if (this._multiSelectActive) {
      this._hartaMap.disableMultiSelect()
    } else {
      this._hartaMap.enableMultiSelect()
    }
  }

  startPolygonSelect() {
    if (!this._hartaMap) return
    if (this._polygonSelectActive) {
      this._hartaMap._endPolygonSelect?.()
    } else {
      this._hartaMap.startPolygonSelect()
    }
  }

  _onPolygonSelectMode(detail) {
    this._polygonSelectActive = !!detail?.active
    if (this.hasBtnPolygonSelectTarget) {
      // Stilul de „activ" e dat de CSS pe [aria-pressed=true] în floating toolbar.
      this.btnPolygonSelectTarget.setAttribute("aria-pressed", String(this._polygonSelectActive))
    }
    if (this._polygonSelectActive) {
      this._setStatus("Desenează poligonul de selecție: click vertecși, dublu-click închide, Esc anulează.", "info")
    }
  }

  _onMultiSelectMode(detail) {
    this._multiSelectActive = !!detail?.active
    if (this.hasBtnMultiSelectTarget) {
      this.btnMultiSelectTarget.setAttribute("aria-pressed", String(this._multiSelectActive))
    }
    this._renderMultiSelectInfo(0)
    this._updateCancelBtnTooltip()
    if (this._multiSelectActive) {
      this._setStatus("Mod selecție multiplă: click pe poligoane (toggle) sau Shift+drag pentru zonă.", "info")
    }
  }

  _onMultiSelectionChanged(detail) {
    const count = detail?.count || 0
    this._renderMultiSelectInfo(count)
    // Badge cu count pe butonul UNIC de cancel — vizibil când multi-select activ + count>0
    if (this.hasMultiCountBadgeTarget) {
      if (count > 0) {
        this.multiCountBadgeTarget.textContent = String(count)
        this.multiCountBadgeTarget.hidden = false
      } else {
        this.multiCountBadgeTarget.hidden = true
      }
    }
    this._updateCancelBtnTooltip()
    // Reactualizează vizibilitatea contextuală — Move/Rotate trebuie să apară
    // când multi-select are items, chiar fără un single-selected feature.
    this._updateToolbarVisibility?.()
    // Tooltip-uri butoane bulk
    if (this.hasBtnMoveTarget && count > 0 && this._multiSelectActive) {
      this.btnMoveTarget.title = `Mută bloc ${count} poligoane — drag pe orice, OSnap activ`
      this.btnMoveTarget.disabled = false
    }
    if (this.hasBtnRotateTarget && count > 0 && this._multiSelectActive) {
      this.btnRotateTarget.title = `Rotește bloc ${count} poligoane — click pivot pe un vertex`
      this.btnRotateTarget.disabled = false
    }
  }

  // Buton UNIC „Anulează" — context-aware:
  //  - dacă există desenare activă (draw/edit/post-draw modify) → curăță desenarea
  //  - altfel, dacă există selecție multiplă activă → o DEZACTIVEAZĂ COMPLET
  //    (curăță items + iese din modul multi-select) → revine la single-select
  //  - fallback: clearAll (reset general)
  cancelOperation() {
    if (this._draw || this._postDrawModify || this._editing) {
      this.clearAll()
      this._setStatus("Operațiune anulată.", "info")
      return
    }
    if (this._multiSelectActive) {
      const selCount = this._hartaMap?.getMultiSelection?.()?.length || 0
      // disableMultiSelect curăță selecția + iese din mod → următorul click pe
      // poligon redevine single-select cu butoanele Modifică/Mută/Șterge active.
      this._hartaMap?.disableMultiSelect?.()
      this._setStatus(selCount > 0
        ? `Selecție anulată (${selCount} poligoane). Click pe un poligon = single-select.`
        : "Mod multi-select dezactivat.", "info")
      return
    }
    this.clearAll()
  }

  _updateCancelBtnTooltip() {
    if (!this.hasBtnCancelAllTarget) return
    const selCount = this._hartaMap?.getMultiSelection?.()?.length || 0
    if (this._draw || this._postDrawModify) {
      this.btnCancelAllTarget.title = "Anulează digitizarea curentă"
    } else if (this._multiSelectActive && selCount > 0) {
      this.btnCancelAllTarget.title = `Anulează selecția — ${selCount} poligon(e) selectate`
    } else {
      this.btnCancelAllTarget.title = "Anulează operațiunea curentă"
    }
  }

  _renderMultiSelectInfo(count) {
    if (this.hasMultiSelectInfoTarget) {
      if (!this._multiSelectActive) {
        this.multiSelectInfoTarget.textContent = ""
      } else {
        this.multiSelectInfoTarget.textContent = count === 0
          ? "Selecție multiplă activă — 0 selectate"
          : `${count} selectate`
      }
    }
    // Badge pe butonul din toolbar — afișează N când selecție multiplă activă + count > 0.
    if (this.hasMultiSelectBadgeTarget) {
      if (this._multiSelectActive && count > 0) {
        this.multiSelectBadgeTarget.textContent = String(count)
        this.multiSelectBadgeTarget.hidden = false
      } else {
        this.multiSelectBadgeTarget.hidden = true
      }
    }
  }

  onCleanupThresholdChange() {
    if (!this.hasCleanupSliderTarget) return
    const v = parseFloat(this.cleanupSliderTarget.value)
    if (this.hasCleanupValTarget) this.cleanupValTarget.textContent = v.toFixed(2)
  }

  // Curățare topologică pe zona din multi-selecție (click toggle sau lasso).
  async runCleanupTopology() {
    const sel = this._hartaMap?.getMultiSelection?.() || []
    if (sel.length === 0) {
      this._setCleanupResult('Niciun poligon selectat. Activează „Selecție multiplă" (click toggle sau 🔷 lasso poligon).', "warn")
      return
    }
    const items = sel.map(it => ({ kind: it.kind, id: it.feature.get("id") }))
    await this._executeCleanup(items, "Selecție multiplă")
  }

  // Curățare topologică pe toate poligoanele vizibile în viewport-ul curent.
  // Deduplicare automată: un imobil CGXML poate apărea și în layer-ul cgxml,
  // și în parcele (dacă are cache geometric) — păstrăm o singură intrare.
  async runCleanupViewport() {
    const map = this._hartaMap?.map
    if (!map) {
      this._setCleanupResult("Harta nu e gata.", "warn")
      return
    }
    const ext = map.getView().calculateExtent(map.getSize())
    const seen = new Map()
    const add = (kind, id) => {
      if (!id) return
      const key = `${kind}-${id}`
      if (!seen.has(key)) seen.set(key, { kind, id })
    }
    this._hartaMap.parcelLayer?.getSource().forEachFeatureInExtent(ext, (f) => add("parcela", f.get("id")))
    this._hartaMap.cladiriLayer?.getSource().forEachFeatureInExtent(ext, (f) => add("cladire", f.get("id")))
    this._hartaMap.cgxmlLayer?.getSource().forEachFeatureInExtent(ext, (f) => {
      const et = f.get("entity_type")
      if (et === "land")     add("parcela", f.get("id"))
      if (et === "building") add("cladire", f.get("id"))
    })
    const items = Array.from(seen.values())
    if (items.length === 0) {
      this._setCleanupResult("Niciun poligon vizibil în viewport.", "warn")
      return
    }
    await this._executeCleanup(items, "Viewport vizibil")
  }

  // Helper comun: prompt, POST, afișare rezumat, reload layere.
  async _executeCleanup(items, sourceLabel) {
    const threshold = this.hasCleanupSliderTarget ? parseFloat(this.cleanupSliderTarget.value) : 0.5
    const msg = `Curățare topologică pe ${items.length} poligon(e) (${sourceLabel}) cu prag ${threshold.toFixed(2)} mp.\n\n` +
                `Vor fi snap-uite vertecșii pe laturi comune și eliminate goluri/suprapuneri ≤ ${threshold.toFixed(2)} mp.\n` +
                `Suprafețele se păstrează în ±1 mp; ce depășește = sărit.\n\nContinui?`
    if (!confirm(msg)) return

    [this.hasBtnCleanupTarget && this.btnCleanupTarget,
     this.hasBtnCleanupViewportTarget && this.btnCleanupViewportTarget].forEach(b => { if (b) b.disabled = true })
    this._setCleanupResult(`Curățare ${sourceLabel.toLowerCase()} în curs (${items.length} poligoane)…`, "info")

    try {
      const res = await fetch(this.cleanupUrlValue, {
        method:  "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this._csrf(),
          "Accept":       "application/json"
        },
        body: JSON.stringify({ items, threshold })
      })
      const data = await res.json()
      if (!data.ok) {
        this._setCleanupResult(`Eroare: ${data.error || res.status}`, "warn")
        return
      }
      const lines = []
      lines.push(`<strong>${sourceLabel}: ${data.summary}</strong>`)
      if (data.modified.length) {
        const sample = data.modified.slice(0, 8).map(m => m.label).join(", ")
        const more   = data.modified.length > 8 ? ` (+${data.modified.length - 8})` : ""
        lines.push(`✓ Modificate: ${sample}${more}`)
      }
      if (data.skipped.length) {
        const sample = data.skipped.slice(0, 5).map(s => `${s.label} — ${s.reason}`).join("; ")
        const more   = data.skipped.length > 5 ? ` (+${data.skipped.length - 5})` : ""
        lines.push(`⊘ Sărite: ${sample}${more}`)
      }
      if (data.errors.length) {
        const sample = data.errors.slice(0, 5).map(e => `${e.label}: ${e.message}`).join("; ")
        const more   = data.errors.length > 5 ? ` (+${data.errors.length - 5})` : ""
        lines.push(`⚠ Erori: ${sample}${more}`)
      }
      this._setCleanupResult(lines.join("<br>"), data.errors.length ? "warn" : "ok")
      this._hartaMap?._loadParcele?.()
      this._hartaMap?._loadCladiri?.()
      this._hartaMap?._loadCgxml?.()
    } catch (e) {
      this._setCleanupResult(`Eroare rețea: ${e.message}`, "warn")
    } finally {
      [this.hasBtnCleanupTarget && this.btnCleanupTarget,
       this.hasBtnCleanupViewportTarget && this.btnCleanupViewportTarget].forEach(b => { if (b) b.disabled = false })
    }
  }

  _setCleanupResult(html, kind = "info") {
    if (!this.hasCleanupResultTarget) return
    const color = kind === "warn" ? "#dc2626" : kind === "ok" ? "#16a34a" : "#374151"
    this.cleanupResultTarget.innerHTML = html
    this.cleanupResultTarget.style.color = color
  }

  async deleteMultiSelected() {
    const items = this._hartaMap?.getMultiSelection?.() || []
    if (items.length === 0) {
      this._setStatus("Nicio geometrie selectată.", "warn")
      return
    }
    const nParc = items.filter(i => i.kind === "parcela").length
    const nClad = items.filter(i => i.kind === "cladire").length
    const parts = []
    if (nParc) parts.push(`${nParc} parcelă${nParc === 1 ? "" : "(e)"}`)
    if (nClad) parts.push(`${nClad} clădire${nClad === 1 ? "" : " (i)"}`)
    if (!confirm(`Ștergi ${parts.join(" + ")}?\n\nAceastă acțiune e ireversibilă.`)) return

    this._setStatus(`Se șterg ${items.length} geometrii…`, "info")

    const csrf = this._csrf()
    const results = await Promise.all(items.map(async (it) => {
      const id  = it.feature.get("id")
      const url = it.kind === "cladire"
        ? `/buildings/${id}`
        : `/lands/${id}`
      try {
        const res = await fetch(url, {
          method:  "DELETE",
          headers: { "X-CSRF-Token": csrf, "Accept": "application/json" }
        })
        return { ok: res.ok, id, kind: it.kind, status: res.status }
      } catch (e) {
        return { ok: false, id, kind: it.kind, error: e.message }
      }
    }))

    const okCount   = results.filter(r => r.ok).length
    const failCount = results.length - okCount

    this._hartaMap?.clearMultiSelection?.()
    this._hartaMap?._loadParcele?.()
    this._hartaMap?._loadCladiri?.()

    if (failCount === 0) {
      this._setStatus(`${okCount} geometrii șterse cu succes.`, "ok")
    } else {
      this._setStatus(`Șterse: ${okCount}. Eșuate: ${failCount}.`, "warn")
    }
  }

  editSelected() {
    if (!this._selected) {
      this._setStatus("Selectează un poligon pe hartă (click pe el) înainte de Editează.", "warn")
      return
    }
    // Cache local — clearSelection() declanșează event \"feature-deselected\"
    // care, prin listener, setează this._selected = null. Lucrăm pe referință.
    const sel = this._selected
    this.editKindValue = sel.kind
    this.editIdValue   = String(sel.feature.get("id"))
    this._hartaMap?.clearSelection()
    this._enterEditMode(sel.feature, sel.layer)
  }

  // Folosește _verts (deja cleaned de cursor și closing duplicate) ca să
  // randeze cerculețe roșii la fiecare vertex confirmat. Aplicabil atât la
  // edit cât și la digitizare nouă.
  _renderEditVertices() {
    if (!this._editVertexSource) return
    // Păstrăm vertecșii vecinilor doar-vizuali (statici pe durata edit-ului) —
    // altfel ar dispărea la fiecare re-render declanșat de drag pe primar.
    const keep = this._editVertexSource.getFeatures().filter(f => f.get("visualNeighbor"))
    this._editVertexSource.clear()
    keep.forEach(f => this._editVertexSource.addFeature(f))
    this._verts.forEach(v => {
      this._editVertexSource.addFeature(new ol.Feature(new ol.geom.Point([v.x, v.y])))
    })
    // Re-randăm și vecinii editabili (geometriile lor pot fi modificate)
    if (this._editing && this._editFeatureKindMap) {
      this._editFeatureKindMap.forEach((kind, feat) => {
        if (feat === this._editFeature) return
        this._addAllVertexesAsPoints(feat, this._editVertexSource, true)
      })
    }
    this._renderEditEdgeLabels()
  }

  // Plasează o etichetă cu lungimea fiecărei muchii în interiorul poligonului.
  // Poziția: midpoint-ul muchiei deplasat ușor spre centroid (1m sau 30% din
  // distanța până la centroid), ca textul să fie clar în interior, nu pe linie.
  // Distanța e calculată direct în Stereo70 (metri reali, fără reproiecție).
  _renderEditEdgeLabels() {
    if (!this._editEdgeLabelsSource) return
    this._editEdgeLabelsSource.clear()
    const verts = this._verts
    if (!verts || verts.length < 2) return

    const cx = verts.reduce((s, v) => s + v.x, 0) / verts.length
    const cy = verts.reduce((s, v) => s + v.y, 0) / verts.length

    // Dacă poligonul nu e încă închis (în mod draw), nu desenăm muchia
    // dintre ultimul și primul vertex.
    const closed = !this._draw
    const n = verts.length
    const edgeCount = closed ? n : n - 1
    for (let i = 0; i < edgeCount; i++) {
      const a = verts[i]
      const b = verts[(i + 1) % n]
      const dx = b.x - a.x
      const dy = b.y - a.y
      const dist = Math.hypot(dx, dy)
      if (dist < 0.01) continue
      const mx = (a.x + b.x) / 2
      const my = (a.y + b.y) / 2
      let ox = cx - mx, oy = cy - my
      const olen = Math.hypot(ox, oy)
      if (olen > 0) {
        const offset = Math.min(1.0, olen * 0.3)
        ox = (ox / olen) * offset
        oy = (oy / olen) * offset
      }
      // Rotație în convenția OL (pozitiv = clockwise pe ecran). View-ul e în
      // Stereo70 cu Y nord (sus); pe ecran Y e jos → unghiul geometric e
      // inversat. Normalizăm în [-π/2, π/2] ca textul să nu apară upside-down.
      let rotation = -Math.atan2(dy, dx)
      if (rotation > Math.PI / 2)  rotation -= Math.PI
      if (rotation < -Math.PI / 2) rotation += Math.PI
      const f = new ol.Feature(new ol.geom.Point([mx + ox, my + oy]))
      f.set("distance", dist)
      f.set("rotation", rotation)
      this._editEdgeLabelsSource.addFeature(f)
    }

    // Eticheta cu suprafața în interiorul poligonului — live de la al 3-lea
    // vertex. Poziție: getInteriorPoint() (garantat în polygon, chiar non-convex).
    // În MOD DRAW folosim geometria OL (include cursor) → suprafața vizuală
    // corespunde cu ce vede utilizatorul. La edit / post-draw folosim shoelace
    // pe _verts. Bara de jos (statusArea) e actualizată separat în _updateLiveArea.
    if (verts.length >= 3) {
      let area = 0
      let labelXY = [cx, cy]
      const drawGeom = this._draw ? this._currentFeature?.getGeometry?.() : null
      if (drawGeom && drawGeom.getType() === "Polygon") {
        try {
          area = drawGeom.getArea() || 0
          const ip = drawGeom.getInteriorPoint?.()
          if (ip) labelXY = ip.getCoordinates()
        } catch (_) { /* fallback la shoelace */ }
      }
      if (area === 0) {
        let s = 0
        for (let i = 0; i < n; i++) {
          const a = verts[i]
          const b = verts[(i + 1) % n]
          s += (a.x * b.y) - (b.x * a.y)
        }
        area = Math.abs(s) / 2
      }
      if (area > 0) {
        const af = new ol.Feature(new ol.geom.Point(labelXY))
        af.set("areaLabel", true)
        af.set("area", area)
        this._editEdgeLabelsSource.addFeature(af)
      }
    }
  }

  _addAllVertexesAsPoints(feat, source, isNeighbor = false) {
    const geom = feat.getGeometry()
    if (!geom) return
    const type = geom.getType()
    let rings = []
    if (type === "Polygon")           rings = geom.getCoordinates()
    else if (type === "MultiPolygon") rings = geom.getCoordinates().flat()
    rings.forEach(ring => {
      const verts = ring.length > 1 ? ring.slice(0, -1) : ring
      verts.forEach(coord => {
        const f = new ol.Feature(new ol.geom.Point(coord))
        if (isNeighbor) f.set("neighborVertex", true)
        source.addFeature(f)
      })
    })
  }

  _renderNeighborVertices(neighbors) {
    if (!this._editVertexSource) return
    neighbors.forEach(feat => {
      this._addAllVertexesAsPoints(feat, this._editVertexSource, true)
      // Track changes la geometria vecinului ca să marcăm ca modified
      const onChange = () => {
        this._modifiedFeatures.add(feat)
        // Re-render cerculețele când se modifică
        this._renderEditVertices()
      }
      const key = feat.getGeometry().on("change", onChange)
      this._editFeatureKindMap.set(feat, this._editFeatureKindMap.get(feat) || "parcela")
      // Stash key for cleanup
      if (!this._neighborChangeKeys) this._neighborChangeKeys = []
      this._neighborChangeKeys.push(key)
    })
  }

  _findEditableNeighbors(feature, distMeters = 1.0) {
    if (!this._hartaMap) return []
    const editGeom = feature.getGeometry()
    const editExt  = editGeom.getExtent()
    const buffered = ol.extent.buffer(editExt, distMeters)
    const out = []
    const sources = [
      [this._hartaMap.parcelLayer.getSource(),  "parcela"],
      [this._hartaMap.cladiriLayer.getSource(), "cladire"]
    ]
    sources.forEach(([src, kind]) => {
      src?.forEachFeatureInExtent(buffered, (f) => {
        if (f === feature) return
        // Doar vecini de același tip cu poligonul editat (parcele cu parcele,
        // clădiri cu clădiri); evităm să tragem clădiri când edităm parcele.
        if (kind !== this.editKindValue) return
        out.push({ feature: f, kind })
      })
    })
    return out
  }

  // Vecini doar pentru vizualizare — features din layer-ul CGXML (imobile)
  // care sunt LIPITE de poligonul curent (împart cel puțin un segment de
  // boundary). Verificare geometrică reală cu JSTS — distanța minimă < 5 cm
  // acoperă atât touch exact cât și mici toleranțe de floating-point.
  // Nu intră în Modify interaction; vertecșii apar ca cerculețe gri-bleu.
  _findVisualNeighbors(feature) {
    if (!this._hartaMap?.cgxmlLayer) return []
    const editGeom = feature.getGeometry()
    if (!editGeom) return []
    const kind     = this._draw ? this._entityType : this.editKindValue
    const expectEt = kind === "cladire" ? "building" : "land"
    const out      = []

    // ── Mod DRAW: bbox-proximitate, fără JSTS ─────────────────────────
    // În timpul desenării (chiar cu 1 vertex), arătăm imediat vecinii din
    // raza ~5 m a poligonului curent (bbox extins). Nu folosim JSTS pentru
    // că poligonul cu <3 vertecși are LinearRing invalid (throws). User
    // are referință vizuală în jurul cursor-ului încă de la primul click.
    if (this._draw) {
      const draftRadius = 5.0    // metri în jurul bbox-ului
      const bbox = ol.extent.buffer(editGeom.getExtent(), draftRadius)
      this._hartaMap.cgxmlLayer.getSource().forEachFeatureInExtent(bbox, (f) => {
        if (f === feature) return
        if (f.get("entity_type") !== expectEt) return
        out.push(f)
      })
      return out
    }

    // ── Mod EDIT / POST-DRAW MODIFY: JSTS strict 5 cm ─────────────────
    const bbox     = ol.extent.buffer(editGeom.getExtent(), 0.20)
    const parser   = this._hartaMap._getJstsParser?.()
    let jstsEdit = null
    if (parser) {
      try { jstsEdit = parser.read(editGeom) }
      catch (_) { jstsEdit = null }
    }
    const touchTol = 0.05
    this._hartaMap.cgxmlLayer.getSource().forEachFeatureInExtent(bbox, (f) => {
      if (f === feature) return
      if (f.get("entity_type") !== expectEt) return
      if (jstsEdit) {
        try {
          const jstsCand = parser.read(f.getGeometry())
          if (jstsEdit.distance(jstsCand) > touchTol) return
        } catch (_) { return }
      }
      out.push(f)
    })
    return out
  }

  // Adaugă vertecșii feature-urilor vizuale (gri-bleu cerc) în
  // `_editVertexSource`. Marcați cu `visualNeighbor: true` ca să fie:
  //   (1) stilizați diferit
  //   (2) păstrați prin re-randările din `_renderEditVertices`.
  _renderVisualNeighborVertices(features) {
    if (!this._editVertexSource) return
    features.forEach(f => {
      const geom = f.getGeometry()
      if (!geom) return
      const type = geom.getType()
      const rings = type === "Polygon" ? geom.getCoordinates()
                  : type === "MultiPolygon" ? geom.getCoordinates().flat()
                  : []
      rings.forEach(ring => {
        const verts = ring.length > 1 ? ring.slice(0, -1) : ring
        verts.forEach(coord => {
          const pt = new ol.Feature(new ol.geom.Point(coord))
          pt.set("visualNeighbor", true)
          this._editVertexSource.addFeature(pt)
        })
      })
    })
  }

  // ── EDIT MODE: modify geometrie poligon existent ─────────────────────────

  _waitForFeatureAndEdit() {
    // Layer-ul țintă e deja încărcat (parcele/cladiri) sau în curs; așteptăm
    // până feature-ul cu id-ul cerut e în source. Polling la 200ms (max 5s).
    const start = Date.now()
    const poll  = () => {
      const layer = this.editKindValue === "cladire"
        ? this._hartaMap?.cladiriLayer
        : this._hartaMap?.parcelLayer
      if (!layer) {
        if (Date.now() - start < 5000) return setTimeout(poll, 200)
        return
      }
      const feat = layer.getSource().getFeatures().find(f => String(f.get("id")) === String(this.editIdValue))
      if (feat) return this._enterEditMode(feat, layer)
      if (Date.now() - start < 5000) setTimeout(poll, 200)
      else this._setStatus(`Nu am găsit ${this.editKindValue} #${this.editIdValue} pentru editare.`, "warn")
    }
    poll()
  }

  _enterEditMode(feature, sourceLayer) {
    this._editing = true
    this._editFeature = feature
    this._editSourceLayer = sourceLayer
    this._hartaMap?.setDigitizing(true)

    // Forțează închiderea popup-ului de info (în caz că setDigitizing nu a apucat)
    this._hartaMap?._popup?.setPosition(undefined)
    this._hartaMap?.clearSelection?.()

    // Detectează vecinii (parcele/clădiri în limita 1m) și le include în
    // Modify ca să poți edita simultan vertecșii partajati. Topology-aware
    // editing: drag pe un vertex partajat mută în ambele poligoane.
    this._editFeatureKindMap = new Map()
    this._editFeatureKindMap.set(feature, this.editKindValue)
    const neighbors = this._findEditableNeighbors(feature, 1.0)
    neighbors.forEach(n => this._editFeatureKindMap.set(n.feature, n.kind))

    const allEditFeatures = [feature, ...neighbors.map(n => n.feature)]
    const editColl = new ol.Collection(allEditFeatures)
    this._modify = new ol.interaction.Modify({
      features:       editColl,
      pixelTolerance: 12,
      deleteCondition: (evt) => {
        const oe = evt.originalEvent
        return evt.type === "singleclick" && (oe?.shiftKey || oe?.altKey)
      }
    })
    this.map.addInteraction(this._modify)

    // Tracking modificări — set de features modificate (pentru save batch)
    this._modifiedFeatures = new Set([feature])  // primary always considered modified
    this._modify.on("modifyend", (evt) => {
      evt.features.forEach(f => this._modifiedFeatures.add(f))
    })

    // Render cerculețe portocalii la vecinii editabili (topology-aware)
    this._renderNeighborVertices(neighbors.map(n => n.feature))

    // Vecini doar-vizuali (CGXML imobile din apropiere) — vertecși gri-bleu
    // cerculețe, NU sunt incluși în Modify (nu pot fi dragați).
    const visualNeighbors = this._findVisualNeighbors(feature)
      .filter(f => !this._editFeatureKindMap.has(f))  // evită dublarea pe cei deja editabili
    this._renderVisualNeighborVertices(visualNeighbors)

    // Snap la celelalte features — păstrăm preferințele user-ului (endpoint /
    // midpoint / centroid / nearest), nu forțăm un default care suprascrie
    // toggle-urile din toolbar.
    this._refreshSnap()

    // Extract verts inițial + on change (apelul _renderEditVertices e deja inclus în _extractVerts)
    this._extractVerts(feature.getGeometry())
    this._geomChangeKey = feature.getGeometry().on("change", (e) => {
      this._extractVerts(e.target)
      clearTimeout(this._areaDebounce); clearTimeout(this._topoDebounce)
      this._areaDebounce = setTimeout(() => this._calcArea(), 400)
      this._topoDebounce = setTimeout(() => this._verifyTopology(), 700)
    })

    // Preluăm zoom la feature ca să fie vizibil
    const ext = feature.getGeometry().getExtent()
    this.map.getView().fit(ext, { padding: [60, 60, 60, 60], maxZoom: 19, duration: 250 })

    // Pre-completare „Din act" din `parcellegalarea` (CGXML). `_calcArea` apoi
    // apelează `_updateDiffDisplay` care folosește această valoare.
    if (this.hasAreaActTarget) {
      const act = Number(feature.get("parcellegalarea"))
      this.areaActTarget.value = act > 0 ? act.toFixed(2) : ""
    }

    // Înlocuim butoanele Salvează cu un buton dedicat „Salvează modificări"
    this._injectEditUI()
    this._setStatus(`Editare ${this.editKindValue} #${this.editIdValue} — drag pe vertex pentru a modifica.`, "ok")
    this._calcArea()
    this._verifyTopology()
  }

  _injectEditUI() {
    // Ascund formele de salvare nouă; show un mic header de edit + buton save
    if (this.hasFormParcelaTarget)  this.formParcelaTarget.style.display  = "none"
    if (this.hasFormCladireTarget)  this.formCladireTarget.style.display  = "none"
    const ent = this.element.querySelector(".digi-entity-toggle")
    if (ent) ent.style.display = "none"

    // Inject panou de edit (idempotent). Folosim acelasi pattern de design
    // (header gălbui, hint listă, butoane cu iconuri SVG) ca panoul de mutare.
    if (this.element.querySelector(".digi-edit-panel")) return
    const panel = document.createElement("section")
    panel.className = "digi-section digi-edit-panel"
    panel.innerHTML = `
      <div class="digi-edit-header">Modificare ${this.editKindValue} #${this.editIdValue}</div>
      <ul class="digi-parcela-hint" style="margin:6px 0;padding-left:18px;line-height:1.6">
        <li><b>Drag</b> pe vertex (cerc roșu) → mută vertex</li>
        <li><b>Click pe muchie + drag</b> → adaugă vertex nou</li>
        <li><b>Shift+Click</b> pe vertex → șterge vertex</li>
      </ul>
      <div class="digi-edit-topo-mirror" data-digitizare-target="editTopoMirror"
           style="margin-top:8px;font-size:11px;display:flex;flex-direction:column;gap:3px"></div>
      <button type="button" class="btn btn-primary btn-sm digi-ctx-btn digi-edit-save"
              data-action="click->digitizare#saveEdit">${this._iconSave()} Salvează modificări</button>
      <button type="button" class="btn btn-secondary btn-sm digi-ctx-btn"
              data-action="click->digitizare#cancelEdit">${this._iconCancel()} Anulează</button>
    `
    // Inserăm panoul la TOP-ul panel-body, ca să fie imediat vizibil sub header
    const body = this.hasPanelBodyTarget ? this.panelBodyTarget : this.element
    const firstSection = body.querySelector(".digi-section")
    if (firstSection) body.insertBefore(panel, firstSection)
    else body.appendChild(panel)
    this._updateSaveAvailability()
  }

  async saveEdit() {
    if (!await this._validateBeforeSave()) return

    const m = this._applyMetricSnapping()
    if (m) this._setStatus(`METRIC: ${m} vertex(i) potriviți pe vecini.`, "ok")

    // Construim payload pentru save_batch: primary + vecini modificați
    const primary = {
      kind:         this.editKindValue,
      id:           this.editIdValue,
      geom_wkt:     this._buildWktFromGeom(this._editFeature.getGeometry()),
      suprafata_mp: this._areaCalc > 0 ? this._areaCalc.toFixed(4) : null
    }
    const neighbors = []
    if (this._modifiedFeatures && this._editFeatureKindMap) {
      this._modifiedFeatures.forEach(f => {
        if (f === this._editFeature) return
        const kind = this._editFeatureKindMap.get(f)
        if (!kind) return
        neighbors.push({
          kind:     kind,
          id:       String(f.get("id")),
          geom_wkt: this._buildWktFromGeom(f.getGeometry()),
          suprafata_mp: null  // recalcularea suprafeței la vecini se face server-side la save
        })
      })
    }

    this._setStatus(`Salvare: ${1 + neighbors.length} poligon(e)…`)
    try {
      const res = await fetch(this.saveBatchUrlValue, {
        method:  "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this._csrf(),
          "Accept":       "application/json"
        },
        body: JSON.stringify({ primary, neighbors })
      })
      const data = await res.json()
      if (data.ok) {
        this._setStatus("Salvat ✓", "ok")
        this._exitEditMode()
      } else {
        this._setStatus("Erori la save: " + (data.errors || []).join(" | "), "warn")
      }
    } catch (e) {
      this._setStatus(`Eroare rețea: ${e.message}`, "warn")
    }
  }

  cancelEdit() { this._exitEditMode() }

  // Cleanup sincron al state-ului de edit mode (fără reload de layere, fără
  // reselect). Folosit din `_exitEditMode` și din `deleteSelected` (când
  // ștergerea se face direct din edit mode).
  _resetEditUIState() {
    // Curăță orice transformare interactivă (move/rotate) înainte de exit edit.
    if (this._postDrawTransform) this._cancelTransform()
    if (this._modify && this.map) this.map.removeInteraction(this._modify)
    this._modify = null

    if (this._geomChangeKey) { ol.Observable.unByKey(this._geomChangeKey); this._geomChangeKey = null }
    if (this._neighborChangeKeys) {
      this._neighborChangeKeys.forEach(k => ol.Observable.unByKey(k))
      this._neighborChangeKeys = null
    }

    this._editing            = false
    this._editFeature        = null
    this._editSourceLayer    = null
    this._editFeatureKindMap = null
    this._modifiedFeatures   = null
    this.editKindValue       = ""
    this.editIdValue         = ""

    this._editVertexSource?.clear()
    this._editEdgeLabelsSource?.clear()
    this._verts = []

    if (this.hasFormParcelaTarget) this.formParcelaTarget.style.display = ""
    if (this.hasFormCladireTarget) this.formCladireTarget.style.display = ""
    const ent = this.element.querySelector(".digi-entity-toggle")
    if (ent) ent.style.display = ""
    this.element.querySelector(".digi-edit-panel")?.remove()

    this._areaCalc = 0
    if (this.hasAreaCalcTarget)   this.areaCalcTarget.textContent = "—"
    if (this.hasAreaActTarget)    this.areaActTarget.value = ""
    if (this.hasAreaDiffTarget)   { this.areaDiffTarget.textContent = "—"; this.areaDiffTarget.className = "digi-area-diff" }
    if (this.hasStatusAreaTarget) this.statusAreaTarget.textContent = "—"

    this._hartaMap?.setDigitizing(false)
  }

  // Curăță tot state-ul de edit mode și rămâne pe /harta (fără navigare la /lands/:id).
  // Apelat din saveEdit (după success) și din butonul „Anulează".
  // După reload, re-selectează silent feature-ul ca să rămână evidențiat.
  async _exitEditMode() {
    const editedKind = this.editKindValue       // capturăm înainte de cleanup
    const editedId   = String(this.editIdValue || "")

    this._resetEditUIState()

    this._hartaMap?.clearSelection?.()
    this._selected = null
    this._updateEditButton()
    this._updateToolbarVisibility?.()

    // Reîncarcă layerele (await pentru ca re-highlight să găsească feature-ul nou)
    await Promise.all([
      this._hartaMap?._loadParcele?.(),
      this._hartaMap?._loadCladiri?.(),
      this._hartaMap?._loadCgxml?.()
    ])

    // Re-selectează silent feature-ul editat ca să rămână evidențiat pe hartă.
    // Silent = fără event `feature-selected` (evităm re-intrarea în mod edit).
    if (!editedKind || !editedId) return
    const hm = this._hartaMap
    if (!hm) return
    const cgxmlEt = editedKind === "cladire" ? "building" : "land"
    const layersToSearch = editedKind === "cladire"
      ? [[hm.cladiriLayer, false], [hm.cgxmlLayer, true]]
      : [[hm.parcelLayer,  false], [hm.cgxmlLayer, true]]
    for (const [layer, isCgxml] of layersToSearch) {
      const feat = layer?.getSource().getFeatures().find(f => {
        if (isCgxml) return f.get("entity_type") === cgxmlEt && String(f.get("id")) === editedId
        return String(f.get("id")) === editedId
      })
      if (feat) {
        const sel = { kind: editedKind, feature: feat, layer }
        hm._setSelectedFeature?.(sel, { silent: true })
        // Persistă entitatea editată în URL pentru refresh ulterior.
        hm._updateFocusUrlParams?.(sel)
        // Re-sincronizăm starea pe digitizare (silent select nu fires event)
        // ca toolbar-ul să arate Edit/Mută/Șterge active (selecția există).
        this._selected = sel
        this._updateEditButton()
        this._updateToolbarVisibility?.()
        break
      }
    }
  }

  // Serializează geometry (Polygon sau MultiPolygon) în WKT MULTIPOLYGON
  // direct din coordonatele OL (Stereo 70 nativ).
  _buildWktFromGeom(geom) {
    const type = geom.getType()
    let polygons = []
    if (type === "Polygon")           polygons = [geom.getCoordinates()]
    else if (type === "MultiPolygon") polygons = geom.getCoordinates()
    const polyStrs = polygons.map(rings => {
      const ringStrs = rings.map(ring => {
        // Asigură ring închis
        const closed = ring.length > 0 && (ring[0][0] !== ring[ring.length-1][0] || ring[0][1] !== ring[ring.length-1][1])
          ? [...ring, ring[0]]
          : ring
        return "(" + closed.map(c => `${c[0].toFixed(6)} ${c[1].toFixed(6)}`).join(", ") + ")"
      })
      return "(" + ringStrs.join(", ") + ")"
    })
    return "MULTIPOLYGON(" + polyStrs.join(", ") + ")"
  }

  // În edit mode, suprapunerea se verifică EXCLUDÂND poligonul curent ȘI
  // toți vecinii care au fost modificați în memorie (geometriile lor server
  // sunt încă cele vechi și ar genera fals-pozitive de overlap).
  _verifyTopologyParams() {
    const params = {
      coords:      this._verts.map(v => [v.x, v.y]),
      entity_type: this._editing ? this.editKindValue : this._entityType
    }
    if (this._editing) params.exclude_id = this.editIdValue
    const excludeIds = []
    if (this._editing && this._modifiedFeatures) {
      this._modifiedFeatures.forEach(f => {
        if (f === this._editFeature) return
        excludeIds.push(String(f.get("id")))
      })
    }
    // Mod drum: vecinii afectați (parcele/clădiri) vor fi actualizați ATOMIC
    // în save_drum cu geometriile lor noi (subtrase). Pentru topology check
    // pre-save NU îi includem în DB-side neighbors (ar produce fals-pozitive
    // de overlap cu geometriile lor VECHI, neactualizate încă în baza de date).
    if (this._drumMode && this._drumAffectedNeighbors) {
      this._drumAffectedNeighbors.forEach(n => excludeIds.push(String(n.id)))
    }
    if (excludeIds.length) params.exclude_neighbor_ids = excludeIds
    return params
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  _setStatus(msg, type = "info") {
    this.statusBarTarget.textContent = msg
    this.statusBarTarget.className   = `digi-status digi-status-${type}`
  }

  _csrf() { return document.querySelector('[name="csrf-token"]')?.content ?? "" }
}
