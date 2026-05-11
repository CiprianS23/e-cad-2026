# Jurnal modificări — Modulul GIS

> Lista cronologică a modificărilor pe modulul GIS al aplicației e‑CAD.
> Sesiuni acoperite: **2026‑05‑10** (migrarea la OpenLayers + bazele „CAD în browser” + validare topologică completă) și **2026‑05‑11** (extensii: export pe zonă, import multi‑format, UX).
> Toate modificările sunt **incrementale** și **non‑distructive** asupra schemei e‑CAD: doar fișiere noi sau extinderi controlate ale celor existente.

---

# SESIUNEA 2026‑05‑10 — Migrare la OpenLayers + topologie completă

## 0. Digitizare extinsă pentru clădiri

**Cerință:** entități cadastrale de tip clădire (`CladireCadastrala`) pe lângă parcele, cu legătură spațială automată la parcela care le conține.

**Fișiere modificate:**

- `db/migrate/20260509220002_create_cladiri_cadastrale.rb` — tabelă nouă (geom MultiPolygon EPSG:3844, GIST index).
- `db/migrate/20260509220003_add_parcela_cadastrala_ref_to_cladiri_cadastrale.rb` — FK opțională `parcela_cadastrala_id`.
- `app/models/cladire_cadastrala.rb` — model nou cu validări de bază.
- `app/controllers/cladiri_cadastrale_controller.rb` — CRUD complet + endpoint geojson.
- `app/views/cladiri_cadastrale/show.html.erb` — pagină detalii cu hartă mini.
- `app/controllers/digitizare_controller.rb`, `parcele_cadastrale_controller.rb` — `parcela_cadastrala_id` calculat din `ST_Intersects(parcele.geom, ST_Centroid(cladire.geom))`.
- `app/javascript/controllers/digitizare_controller.js`, `views/digitizare/index.html.erb` — toggle parcelă/clădire în UI.

**Commit‑uri:** `782f48d`, `bb36321`, `a20756b`.

---

## 1. Consolidare hartă + digitizare într‑o singură pagină

**Cerință:** elimină split‑ul artificial între pagina `/harta` (vizualizare) și pagina `/digitizare` (editare) — totul într‑o singură interfață la `/harta`.

**Fișiere modificate:**

- `app/views/harta/index.html.erb` — devine pagina principală cu panou lateral pentru digitizare (înainte vizualizare‑only).
- `app/views/parcele_cadastrale/show.html.erb`, `cladiri_cadastrale/show.html.erb` — link‑uri „Editează în hartă” spre `/harta?id=...`.
- `app/controllers/digitizare_controller.rb`, `cladiri_cadastrale_controller.rb` — endpoint‑uri JSON păstrate, view-ul `digitizare/index` retras.
- `app/javascript/controllers/digitizare_controller.js`, `harta_map_controller.js`, `layer_switcher_controller.js` — unificare logică.

**Commit:** `79de207` (Leaflet, punct de plecare migrare la OL).

---

## 2. Migrare Leaflet → OpenLayers 10 (Fazele 0–3)

**Cerință:** „CAD feel în browser” — Leaflet nu suportă nativ Stereo70 și nu are unelte CAD‑like; trecere la OpenLayers + ol‑ext + jsts.

### Faza 0 — Layout
**Fișiere modificate:** `app/views/layouts/application.html.erb`, `.gitignore`, `CLAUDE.md` — Leaflet eliminat, OpenLayers 10 + ol‑ext + jsts + proj4 încărcate via importmap.
**Commit:** `248f4d2`.

### Faza 1 — Paritate `/harta` în OL
**Fișiere modificate:** `app/javascript/controllers/harta_map_controller.js` rescris complet (TileLayer ortofoto, VectorSource pentru parcele/clădiri, popup‑uri pe click). `application.css` adaptat.
**Commit:** `72e440e`.

### Faza 2 — Paritate digitizare (Draw + Snap)
**Fișiere modificate:** `app/javascript/controllers/digitizare_controller.js` rescris pentru `ol/interaction/Draw` + `Snap`. Backup‑ul Leaflet păstrat ca `digitizare_controller.js.leaflet-bak`.
**Commit:** `c3e490d`, fix‑uri `abf9053`, `1ad436b`.

### Faza 3 — Snap multi‑mode + linia de comandă + status bar + ortho mode
**Fișiere modificate:** `app/javascript/controllers/digitizare_controller.js` extins cu:

- Snap selectabil per tip: **endpoint / midpoint / intersection / nearest** (toggle în status bar).
- **Toleranță snap configurabilă** în status bar (0.00–0.50 m).
- **Linia de comandă** — input text live pentru coordonate absolute Stereo70 sau distanță relativă.
- **Ortho mode (F8)** — constrânge cursor‑ul la unghi 0°/90° față de ultimul punct.
- **Status bar** — afișează coordonate X/Y Stereo70 live, sistem proiecție, scară curentă, suprafața în construcție.

**Commit:** `6c14e10`, fix‑uri `2d50445`, `9eafe54`, `f1ec372`.

---

## 3. Linia de comandă — workflow AutoCAD complet

**Cerință:** specialiștii cadastru sunt obișnuiți să introducă distanțe din tastatură („tastez 15 enter, click direcție”).

**Fișiere modificate:**

- `app/javascript/controllers/digitizare_controller.js` — input distanță‑only (`15` ⇒ următorul punct la 15 m în direcția cursor‑ului), auto‑start drawing dacă nu există sketch activ, auto‑pan la punct nou când iese din viewport, feedback vizibil la fiecare punct adăugat.
- `app/views/harta/index.html.erb` — slot CLI lângă status bar.

**Commit‑uri:** `68ae09b`, `c545a9e`, `f84f37c`.

---

## 4. OpenLayers View în Stereo70 nativ (fără round‑trip Web Mercator)

**Cerință:** stocarea e în EPSG:3844, dar OL by default lucrează în 3857 → toate round‑trip‑urile pierdeau precizia. Soluție: declarăm proj4 + View nativ în 3844.

**Fișiere modificate:**

- `app/javascript/controllers/harta_map_controller.js`, `digitizare_controller.js` — `proj4.defs("EPSG:3844", ...)`, `ol.proj.fromLonLat` / `transform` eliminate, View cu `projection: "EPSG:3844"`.
- `app/controllers/digitizare_controller.rb`, `app/models/parcela_cadastrala.rb`, `cladire_cadastrala.rb` — query‑uri SQL fără `ST_Transform(geom, 4326)`, totul în 3844.
- `mapproxy/mapproxy.yaml` — sursa de tile‑uri configurată pentru a putea servi 3844 (raster reproject pe server).

**Commit‑uri:** `5c00faf`, `fd0b5b6`.

---

## 5. OSnap cu toleranță 0 — anti‑sliver strict

**Cerință:** clientul (specialist cadastru) cere alinierea **exactă** la vertex existent, nu „aproape exactă”. Snap-ul tolera 0.01 m care producea sliver-uri.

**Fișiere modificate:**

- `app/controllers/digitizare_controller.rb` — validare server cu toleranță 0 la matching vertex.
- `app/models/parcela_cadastrala.rb`, `cladire_cadastrala.rb` — `ST_Equals` strict pe vertecșii partajați.
- `app/javascript/controllers/digitizare_controller.js` — `Snap pixelTolerance: 0` pentru moduri strict; `c74755b` — fix asimetrie OSnap (include toate features‑urile în snap‑targets).

**Commit‑uri:** `35145f2`, `c74755b`.

---

## 6. Validare topologică completă (client + server)

**Cerință:** blochează la salvare orice geometrie cu defecte topologice; afișează erorile direct pe hartă.

**Tipuri de erori detectate:**

- Overlap între parcele (sau între clădiri).
- Sliver polygons (suprapuneri sub prag, semnalate, nu corectate automat).
- Vertex‑on‑vertex (vertex al unui poligon cade pe muchia altuia fără a fi vertex acolo).
- Clădire care traversează mai mult de o parcelă.
- Gap real între poligoane vecine (detectat dinamic, nu marcaj static).
- Geometrii self‑intersecting / invalide (`ST_IsValid`).

**Fișiere modificate:**

- `app/models/parcela_cadastrala.rb`, `cladire_cadastrala.rb` — validări: `geom_topologic_valid`, `nu_se_suprapune_cu_alte_parcele`, `nu_se_suprapune_cu_alte_cladiri`, `geom_nu_e_duplicat`, `nu_traverseaza_mai_multe_parcele` (cu suport `_excluded_neighbors_ids` pentru save batch).
- `app/controllers/digitizare_controller.rb` — endpoint nou `POST /digitizare/audit` care rulează toate verificările pe un subset (sau tot UAT‑ul) și întoarce listă structurată de erori cu geometrii.
- `config/routes.rb` — rută `digitizare#audit`.
- `app/javascript/controllers/digitizare_controller.js` — verificări replicate în browser (jsts) la `drawing` și `modifying`, marker‑e vizuale (overlap roșu, sliver portocaliu, vertex‑off albastru), blocare buton **Salvează** cât timp există erori.
- `app/views/harta/index.html.erb` — panou „Topologie” cu listă categorisită + buton **Scanează erori**.
- `app/assets/stylesheets/application.css` — stiluri pentru evidențiere.

**Save batch 2‑fază (anti‑fals‑overlap):**

- Fix `bde9d25`: la salvarea unui batch de poligoane editate simultan, faza 1 = scrie toate, faza 2 = validează — altfel poligonul 1 vede poligonul 2 cu geometria veche.
- Fix `f6e2658`: snapshot pre‑edit + delta check — raportăm **doar overlap‑urile NOI**, nu pe cele care existau deja.
- Fix `82f5927`, `e2ac0f8`: overlap‑urile virtuale (sub 1 mm²) și gap‑urile virtuale între poligoane perfect aliniate filtrate.

**Commit‑uri:** `de4de01`, `9d7d886`, `9a4140c`, `f73eeac`, `6ed1228`, `82ca5ac`, `22d6882`, `f9a985a`, `f93b3d7`, `bde9d25`, `f6e2658`, `f905f82`, `82f5927`, `e2ac0f8`.

---

## 7. Edit mode pe poligoane existente, topology‑aware

**Cerință:** click pe parcelă/clădire pe hartă → buton „✎ Editează” → dragabil vertex cu vertex; drag pe vertex partajat cu un vecin **mută în ambele poligoane** simultan (păstrează topologia).

**Fișiere modificate:**

- `app/javascript/controllers/digitizare_controller.js` — mod nou `_editingFeature` cu `ol/interaction/Modify`, cerculețe roșii la fiecare vertex (vizibilitate vertecși coliniari), `Shift+Click` pe vertex = ștergere, propagare modificări la vecini prin matching pe coordonate exacte, exclude vecinii modificați din verificările de overlap pe iterații intermediare.
- `app/views/harta/index.html.erb`, `parcele_cadastrale/show.html.erb`, `cladiri_cadastrale/show.html.erb` — buton „Editează în hartă”.
- `app/controllers/cladiri_cadastrale_controller.rb`, `config/routes.rb` — rută `update_geom` separată.
- `app/javascript/controllers/harta_map_controller.js` — exposes feature‑ul selectat pentru `digitizare_controller`.

**Fix‑uri progresive:** `bab03dd`, `c241eed`, `3fbc765`, `2d202b6` (cache `_selected` înainte de side‑effect‑uri), `70171c9` (`_extractVerts` corect pentru `MultiPolygon`), `eec0475` (Shift+Click delete + form submit), `863137d` (vizualizare vertecși), `58e6d0a` (drag pe vertex partajat).

---

## 8. Etichete dinamice pe poligoane

**Cerință:** numărul cadastral + suprafața să apară direct pe hartă, nu doar în popup.

**Fișiere modificate:**

- `app/javascript/controllers/harta_map_controller.js` — `_parcelLabelStyle(feature, resolution)`, `_cladireLabelStyle(feature, resolution)`: text `nr_cadastral` pe rândul 1, `N mp` pe rândul 2, poziționat pe `getInteriorPoint()` (cu fallback pentru `MultiPolygon`).

Pragul de scară a fost adăugat ulterior pe 11 mai (vezi §7 din sesiunea următoare).

**Commit:** `f9281f7`.

---

## 9. Infrastructure — deploy Render + Dockerfile cu GEOS/PROJ

**Cerință:** posibilitatea unui deploy rapid pe Render (PaaS) cu PostGIS și toate dependențele native (GEOS, PROJ, GDAL).

**Fișiere modificate:**

- `render.yaml` — configurație web service + PostgreSQL+PostGIS.
- `Dockerfile` — `apt install libgeos-dev libproj-dev gdal-bin libgdal-dev` în build stage.

**Commit‑uri:** `f207fc4`, `46e9d58`.

---

## Sumar fișiere atinse — sesiunea 10 mai

```
app/views/layouts/application.html.erb
app/views/harta/index.html.erb
app/views/parcele_cadastrale/show.html.erb
app/views/cladiri_cadastrale/show.html.erb
app/views/digitizare/index.html.erb            (retras)
app/controllers/digitizare_controller.rb
app/controllers/parcele_cadastrale_controller.rb
app/controllers/cladiri_cadastrale_controller.rb
app/models/parcela_cadastrala.rb
app/models/cladire_cadastrala.rb
app/javascript/controllers/digitizare_controller.js
app/javascript/controllers/harta_map_controller.js
app/javascript/controllers/layer_switcher_controller.js
app/assets/stylesheets/application.css
config/routes.rb
db/migrate/20260509220002_create_cladiri_cadastrale.rb
db/migrate/20260509220003_add_parcela_cadastrala_ref_to_cladiri_cadastrale.rb
db/schema.rb
mapproxy/mapproxy.yaml
Dockerfile
render.yaml
.gitignore
CLAUDE.md
```

**Schema bazei de date a fost extinsă cu o singură tabelă nouă (`cladiri_cadastrale`) și o FK; restul schemei e‑CAD nu a fost atinsă.**

---

# SESIUNEA 2026‑05‑11 — Extensii: export pe zonă, import multi‑format, UX

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

## Sumar fișiere atinse — sesiunea 11 mai

```
config/routes.rb
app/controllers/digitizare_controller.rb
app/controllers/uat_boundaries_controller.rb
app/views/harta/index.html.erb
app/javascript/controllers/digitizare_controller.js
app/javascript/controllers/harta_map_controller.js
```

**Niciun model existent nu a fost modificat în 11 mai. Schema bazei de date nu a fost atinsă în 11 mai.**
