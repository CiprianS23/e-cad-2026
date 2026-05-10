# Jurnal modificări — Modulul GIS

> Lista cronologică a modificărilor făcute în această sesiune (2026‑05‑11) pe modulul GIS al aplicației e‑CAD.
> Toate modificările sunt **incrementale** și **non‑distructive** asupra schemei e‑CAD: doar fișiere noi sau extinderi controlate ale celor existente.

---

## 1. Export zonă selectată (DXF / KML / GPKG)

**Cerință:** "Funcționalitatea de export DXF trebuie extinsă și la formate GPKG, KML. Să se poată selecta cu mouse o anumită zonă pentru export."

**Fișiere modificate:**

- `config/routes.rb` — rută nouă `POST /digitizare/export_zone`.
- `app/controllers/digitizare_controller.rb`
  - acțiune nouă `export_zone` care primește `area_wkt`, `format`, `layers[]`;
  - helperi: `collect_features_in_zone`, `build_dxf_multi`, `build_kml`, `build_gpkg`, `parse_polygon_wkt`, `build_dxf_text`;
  - require nou: `shellwords`, `tmpdir`, `json`.
- `app/views/harta/index.html.erb` — secțiune **Export** redesignată: butoane "▭ Dreptunghi" și "✏️ Poligon" pentru selecție; dropdown format; checkbox‑uri Parcele/Clădiri.
- `app/javascript/controllers/digitizare_controller.js`
  - target‑uri noi: `btnExportZone`, `btnExportZonePoly`, `btnExportZoneSubmit`, `exportFormat`, `exportLayerParcele`, `exportLayerCladiri`, `exportStatus`;
  - metode: `startExportZoneSelect(evt)` (rect sau poligon liber), `clearExportZone()`, `exportZone(evt)`, `_updateExportStatus()`, `_isRectangle()`.

**Detalii:**

- Selecția acceptă dreptunghi (Draw `Circle` + `createBox`) sau **poligon neregulat** (Draw `Polygon`, dublu‑click pentru închidere).
- Geometria de selecție trimisă serverului în EPSG:3844 (nativ, fără round‑trip).
- Inclus în export = orice geometrie **intersectată sau conținută** de poligonul de selecție (`ST_Intersects`).
- **GPKG** generat prin `ogr2ogr` (GDAL) din KML‑ul intermediar; verifică `which ogr2ogr` și raportează eroare dacă lipsește.
- DXF include layere `PARCELE`, `CLADIRI`, `PARCELE_TEXT`, `CLADIRI_TEXT` cu entități TEXT (numar cadastral + suprafața în mp) centrate pe `ST_PointOnSurface`.
- KML include `<name>` = nr cadastral, `<description>` + `<ExtendedData>` cu suprafața.

---

## 2. Import fișiere KML / GPKG (extindere import DXF)

**Cerință:** "Import fișiere: trebuie să accepte și format GPKG, KML."

**Fișiere modificate:**

- `config/routes.rb` — rută nouă `POST /digitizare/parse_geo_file`.
- `app/controllers/digitizare_controller.rb` — acțiune `parse_geo_file` care folosește `ogr2ogr` pentru a converti orice `.dxf|.kml|.gpkg` în GeoJSON EPSG:3844 (`-t_srs EPSG:3844 -dim XY`) și grupează poligoanele pe layer (`Layer` / `layer` / `Folder` / `Name` / basename).
- `app/views/harta/index.html.erb` — input de import acceptă acum `.dxf,.kml,.gpkg`; label rebraduit "Import fișier (DXF / KML / GPKG)".
- `app/javascript/controllers/digitizare_controller.js`
  - `onDxfFileSelected(evt)` detectează extensia: `.dxf` parsat în client (rapid, fără upload), `.kml`/`.gpkg` urcate la server prin `_parseGeoFileServer()`;
  - UI‑ul de mapping layer→categorie (parcela/clădire/sector/ignoră) e refolosit indiferent de format.

---

## 3. Click‑to‑zoom contextual pe poligoane

**Cerință:** "La click în hartă pe un poligon să facă zoom‑in pe regiunea unde se află acel poligon, dar contextual (nu prea aproape)."

**Fișiere modificate:**

- `app/javascript/controllers/harta_map_controller.js`
  - handler `singleclick` apelează `_zoomToFeature(selected.feature)`;
  - metodă nouă `_zoomToFeature(feature)` — extinde extent‑ul poligonului matematic cu factor `k=5` față de centroid (poligonul ocupă ~20 % din viewport, context vizibil în jur);
  - minim 5 m pe fiecare jumătate pentru entități foarte mici (ex. clădiri compacte);
  - animație 400 ms.

---

## 4. Audit topologie dinamic pe viewport

**Cerință:** "Verificarea de topologie să fie dinamică în sensul că la zoom‑in să restrângă lista de erori doar la ce este în viewport."

**Fișiere modificate:**

- `app/javascript/controllers/digitizare_controller.js`
  - `_renderAuditResults(data)` — cache `_auditIssues` și `_auditIssueExtents` (extent per issue);
  - listener nou `map.on("moveend", () => _filterAndRenderAuditByViewport())` (înregistrat o singură dată via flag `_auditMoveBound`);
  - `_filterAndRenderAuditByViewport()` — calculează extent‑ul viewport (`view.calculateExtent(map.getSize())`) și filtrează cu `ol.extent.intersects`;
  - `_renderAuditList(items, totalCount)` — afișează count vizibil + număr ascuns ("N ascunse — în afara viewport");
  - `clearAudit()` dezleagă listener‑ul.

---

## 5. Fallback automat OSM când MapProxy e offline

**Cerință:** "Nu mai este vizibilă harta OpenStreetMap."

**Fișiere modificate:**

- `app/javascript/controllers/harta_map_controller.js`
  - sursa OSM via MapProxy ascultă `tileloaderror`;
  - la primul eșec se dezleagă listener‑ul, se elimină stratul vechi și se inserează `ol.source.OSM()` (3857 cu reproject OL);
  - log informativ în consolă: "MapProxy indisponibil — fallback OSM 3857 (reproject)".

Soluția e tolerantă la lipsa serverului MapProxy (dezvoltare locală fără setup complet).

---

## 6. Limita UAT — doar acolo unde există geometrii

**Cerință:** "Limita UAT nu este vizibilă" + "Trebuie să arate doar limita UAT în care sunt geometrii."

**Fișiere modificate:**

- `app/controllers/uat_boundaries_controller.rb`
  - **mod default** (`/uat_boundaries/geojson` fără params) → returnează DOAR UAT‑urile care intersectează cel puțin o parcelă sau clădire din DB, prin `EXISTS (SELECT 1 FROM parcele_cadastrale ...)` + `EXISTS (... cladiri_cadastrale ...)`;
  - mod `?lat=&lng=` — UAT‑ul care conține un punct WGS84 (păstrat pentru compatibilitate);
  - mod `?all=1` — toate UAT‑urile (~1.6 MB, fallback);
  - **eliminat** `ST_Transform(geom, 4326)` din toate query‑urile → endpoint returnează coordonate native EPSG:3844 (consistent cu restul aplicației).
- `app/javascript/controllers/harta_map_controller.js` — `_loadUatForCenter` simplificat: doar `fetch(uatUrl)` fără parametri.

---

## 7. Etichete vizibile sub o scară configurabilă

**Cerință:** "La zoom‑out mare nu mai trebuie să se afișeze etichetele" → "Etichetele ar trebui să apară de la scara 1:10000."

**Fișiere modificate:**

- `app/javascript/controllers/harta_map_controller.js`
  - constante noi:
    ```js
    const LABEL_MAX_RESOLUTION         = 2.645   // ≈ 1:10 000
    const LABEL_MAX_RESOLUTION_CLADIRI = 2.645   // ≈ 1:10 000
    ```
  - `_parcelLabelStyle(feature, resolution)`, `_cladireLabelStyle(feature, resolution)`, `_cgxmlLabelStyle(feature, resolution)` returnează `null` când `resolution > prag`.

Convenția pentru scara DPI 96: `scale ≈ resolution × 3779.5`.

---

## Sumar fișiere atinse

```
config/routes.rb
app/controllers/digitizare_controller.rb
app/controllers/uat_boundaries_controller.rb
app/views/harta/index.html.erb
app/javascript/controllers/digitizare_controller.js
app/javascript/controllers/harta_map_controller.js
```

**Niciun model existent nu a fost modificat. Schema bazei de date nu a fost atinsă.**
