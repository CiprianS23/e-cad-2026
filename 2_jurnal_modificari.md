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

## Sumar fișiere atinse — sesiunea 11 mai (partea 1)

```
config/routes.rb
app/controllers/digitizare_controller.rb
app/controllers/uat_boundaries_controller.rb
app/views/harta/index.html.erb
app/javascript/controllers/digitizare_controller.js
app/javascript/controllers/harta_map_controller.js
```

**Niciun model existent nu a fost modificat în prima parte a zilei. Schema nu a fost atinsă.**

---

# SESIUNEA 2026‑05‑11 (partea 2) — Georeferențiere planuri vechi

**Context:** primitiva nouă „upload imagine cadastrală scanată/PDF + plasare GCP-uri pe imagine și pe harta de referință → produce GeoTIFF georeferențiat în Stereo70 + afișare pe harta principală". Spec §6 din `1_modul_gis.md`. Toate tabelele noi au prefix `gis_` pentru a fi ușor de identificat la livrare.

## 1. Modele și schema — `gis_georef_plans` + `gis_georef_control_points`

**Cerință:** persistă planuri raster + GCP-urile (puncte de control pixel↔world).

**Fișiere create:**

- `db/migrate/20260511190001_enable_postgis_raster.rb` — `CREATE EXTENSION postgis_raster` (opțional, pentru viitoare stocare raster nativă în DB).
- `db/migrate/20260511190002_create_gis_georef_plans.rb` — tabelă plan (owner_token din cookie semnat ca placeholder pentru user_id la integrare; coloane: name, description, state, original_width/height, transform_type, transform_params jsonb, residual_rms, bounds_geom geometry(Polygon, 3844)).
- `db/migrate/20260511190003_create_gis_georef_control_points.rb` — tabelă GCP (FK plan, pixel_x/y, world_x/y, ordinal, residual, note).
- `db/migrate/20260511190004_create_active_storage_tables.active_storage.rb` — sistem ActiveStorage (raster_file + warped_file + previewuri).
- `app/models/gis_georef_plan.rb` — model cu has_one_attached pentru `raster_file`, `raster_preview_file`, `warped_file`, `warped_preview_file`. States: `draft | georeferenced | finalized`. Metode: `prepare_for_display!` (rulează la upload pentru a citi dimensiuni + genera preview browser), `recompute_georeference!` (preview afină rapidă), `finalize_warp!` (rulează `RasterWarper`).
- `app/models/gis_georef_control_point.rb` — model GCP cu validări (pixel/world numerice, ordinal>=0, world_not_duplicate_in_plan pentru a preveni „Transform is not solvable" în gdalwarp).

---

## 2. Servicii GDAL — `RasterPreviewer` + `RasterWarper` + transformări

**Cerință:** browser-ele nu suportă nativ TIFF/PDF — avem nevoie de conversie + de un pipeline robust de georeferențiere care să accepte diverse configurări de benzi.

**Fișiere create:**

- `app/services/gis/raster_previewer.rb` — `to_web_preview(source_path, max_dim:, quality:, preserve_alpha:)` cu detecție automată de benzi (Palette → expand RGB, Byte vs alte tipuri → `-ot Byte -scale`); încearcă JPEG, fallback PNG; opțiunea `preserve_alpha: true` forțează PNG pentru a păstra margins transparente (warped output cu `-dstalpha`).
- `app/services/gis/affine_transform.rb` — fit afin 6 parametri din ≥3 GCP-uri (least-squares); folosit pentru preview rapid în-browser (`recompute_georeference!`).
- `app/services/gis/similarity_transform.rb` — fit Helmert improper 4 parametri (translate + rotate + scale uniform) cu y-flip explicit (`Y = b·col − a·row + ty`); modelul corect pentru planuri cadastrale scanate care nu au distorsiuni interne.
- `app/services/gis/raster_warper.rb` — pipeline GDAL: `gdal_translate -expand rgba` (pentru palette indexed scans) → VRT cu GCP-uri SAU GeoTransform similitudine → `gdalwarp -t_srs <proj4_stereo70>` → `gdaladdo` overviews 2/4/8/16/32×. Constantă `STEREO70_PROJ4` folosită direct (codul EPSG:3844 are axă oficială X=north,Y=east care diferă de proj4/OL X=east,Y=north). Default method: `"similarity"`. Output LZW + TILED + BIGTIFF (693MB → 17-52MB).

---

## 3. Controllere și rute REST

**Fișiere create:**

- `app/controllers/gis/georef_plans_controller.rb` — CRUD complet: `index/new/create/show/edit/update/destroy/georeference/finalize/regenerate_preview`. Upload via multipart; `prepare_for_display!` rulat sincron după save (pentru >100MB e nevoie de Sidekiq job — deferat). `display_url` returnează preview-ul când există, altfel TIFF brut.
- `app/controllers/gis/georef_control_points_controller.rb` — CRUD pentru GCP-uri (create/update/destroy). `:ordinal` SCOS din permit — server-authoritative (model îl atribuie via before_validation).
- `config/routes.rb` — resources `gis/georef_plans` cu member routes `georeference` și `finalize`; nested resources `:control_points`.

---

## 4. Editor dual-viewport — `georef_editor_controller.js`

**Cerință:** ecran cu două panouri: stânga = imaginea sursă (în coord pixel), dreapta = harta de referință în Stereo70. Click pe sursă → marker pending. Click pe referință SAU coord manuale → GCP-ul se salvează.

**Fișier creat:** `app/javascript/controllers/georef_editor_controller.js` (~880 linii).

**Funcționalități cheie:**

- **Source pane** (`_buildSourceMap`): OL Map cu proiecție custom `PLAN-PIXEL` (units: pixels, extent [0, -H, W, 0]); afișează preview-ul PNG/JPG via `ol.source.ImageStatic`; rotație animată (slider 0-360° + butoane ±90°) — doar vizual, coords pixel rămân autoritare.
- **Reference pane** (`_buildReferenceMap`): OL Map în EPSG:3844 cu base layers (OSM direct, Google Sat/Hybrid, Esri World Imagery, Ortofoto ANCPI via MapProxy); overlay-uri vector pentru parcele/clădiri/UAT/CGXML; grid Stereo70 1:5000 cu spațiere configurabilă (500m/1000m/2000m/5000m) și etichete X/Y la intersecții; auto-fit pe extent-ul datelor reale.
- **Snap inteligent** (`_findNearestVertex` + `_snapToGridIntersection`): la click pe referință, prioritate (1) vertex cel mai apropiat de o geometrie vizibilă în limita ~15px, (2) intersecție grid Stereo70 dacă grid vizibil, (3) coord click direct. Înlocuiește comportamentul anterior de „centroid parcelă" care făcea ca toate click-urile pe aceeași parcelă să producă același world.
- **Coordonate manuale**: input X/Y în Stereo70 pentru cazurile când utilizatorul cunoaște coordonatele exacte (de ex. de pe planul vechi marcat cu coords).
- **Marker style**: cerc roșu radius 12 cu numărul GCP-ului (cifre albe pe outline negru). În-flight pendingul e galben.
- **Anti-duplicate preflight**: înainte de POST verifică dacă world-ul ales coincide cu un GCP existent (tol 1cm) → eroare clară fără cerere de rețea.

---

## 5. Afișare pe harta principală — `harta_map_controller.js` (extensii)

**Cerință:** planurile cu `state ∈ {georeferenced, finalized}` apar automat pe `/harta` ca image overlays.

**Fișiere modificate:**

- `app/javascript/controllers/harta_map_controller.js`
  - `_loadGeorefPlans()` — fetch `/gis/georef_plans`, filter `state` finalized/georeferenced, pentru fiecare apelează `_addGeorefLayer(planId)`.
  - `_addGeorefLayer(planId)` — fetch detalii plan, creează `ol.layer.Image` cu `ol.source.ImageStatic({url: display_url, imageExtent: bounds_extent, projection: EPSG:3844})` și `zIndex: 90`. Salvează în `this._georefLayers[planId]` pentru control individual.
  - `_makeGeorefSource(url, bounds, bgTransparent)` — fabrică pentru sursa OL; când `bgTransparent=true` injectează un `imageLoadFunction` care procesează canvas pixel-cu-pixel (pixelii R,G,B toți ≥230 → alpha=0).
  - `_resolveLayer(key)` — recunoaște cheia `georef_plan_<id>` și mapează la layer-ul corespunzător.
  - Eveniment `harta-map:georef-loaded` dispatched după ce toate planurile sunt încărcate → notifică Layer Manager să re-fetch prefs.

---

## 6. Layer Manager — categoria „raster" + toggle bg_transparent

**Cerință:** fiecare plan georeferențiat apare ca rând distinct în Layer Manager cu controale (vizibilitate, opacitate, toggle „ascunde fundal alb").

**Fișiere modificate:**

- `app/models/gis_user_layer_pref.rb`
  - Chei dinamice `georef_plan_<id>` în plus față de cele statice (`STATIC_KEYS`). `valid_key?` acceptă regex `\Ageoref_plan_\d+\z`.
  - `full_prefs_for(owner_token)` includ automat planurile finalizate ale utilizatorului prin `GisGeorefPlan.for_owner(owner_token).where(state: %w[georeferenced finalized])`.
  - `georef_plan_defaults(plan, index)` — config implicit pentru un raster: `category: "raster"`, `opacity: 1.0`, `bg_transparent: true`, `z_index: 75 - index` (sub UAT 100, peste base 50).
- `db/migrate/20260511210001_add_bg_transparent_to_gis_user_layer_prefs.rb` — coloană nouă booleană (default nil, fallback la default-ul layer-ului).
- `app/javascript/controllers/layer_manager_controller.js`
  - `_rowHtml` — pentru `category === "raster"` afișează doar controalele de vizibilitate + opacitate + checkbox „Ascunde fundalul alb"; ascunde controalele stroke/fill/dash (irelevante pentru raster).
  - Listener pentru `harta-map:georef-loaded` → re-fetch prefs (planurile vin async după inițializarea hărții).
  - `changeBgTransparent` action → PATCH `/gis/layer_prefs/georef_plan_<id>` cu `bg_transparent: bool` → `applyLayerConfig` în harta_map_controller recreează sursa cu/fără filtru.

---

## 7. Bug-fixe critice (după primul testing utilizator)

### 7.1 GCP ordinals toate ord=0
**Simptom:** după click + plasare GCP, markerii apăreau corect inițial, apoi toate se renumiseau la „1".
**Cauză:** modelul folosea `self.ordinal ||= ...`; coloana avea `default: 0` în DB, deci `cp.ordinal` la `.new()` returna 0 (nu nil), iar `||=` nu suprascrie 0 (truthy în Ruby).
**Fix:** migrare nouă `20260511200001_fix_gis_gcp_ordinals.rb` — `change_column_default :ordinal, nil` + backfill rândurile existente cu valori secvențiale per plan. Plus model: `self.ordinal = ...` (atribuire necondiționată), robust și la schema cache stale pe server-ul deja pornit.

### 7.2 GCP duplicate → gdalwarp eșuat
**Simptom:** `gdalwarp eșuat: Transform is not solvable`.
**Cauză:** click pe aceeași parcelă în reference pane folosea centroidul ei ca țintă → toate GCP-urile aveau același (world_x, world_y) → matrice singulară.
**Fix dublu:**
- Snap la vertex în loc de centroid (vezi §4 — `_findNearestVertex`).
- Validare server-side `world_not_duplicate_in_plan` (tol 1 cm).

### 7.3 Preview warped negru
**Simptom:** TIFF-ul finalizat afișa pixel negri în loc de detaliile cadastrale.
**Cauză:** sursa BERESTI.tif e palette indexed (1 bandă Palette + 1 bandă Alpha). gdalwarp `-r bilinear` interpola indecșii paletei = garbage.
**Fix:** `prepare_source(source_path, dir)` în `RasterWarper` — detectează palette și rulează `gdal_translate -expand rgba` ÎNAINTE de resample. Output curat RGBA.

### 7.4 Distorsiune polinomială
**Simptom:** la 6 GCP-uri, `choose_order(6) = 2` (polinom grad 2) îndoia imaginea.
**Fix:** `choose_order` returnează acum mereu `"similarity"`. Polinomul rămâne opțional în dropdown pentru planuri cu distorsiuni interne reale (≥10 GCP-uri).

### 7.5 Rotație 90° pe raster afișat
**Simptom:** planul apărea rotit la 90° spre stânga față de nord.
**Cauză:** modelul `SimilarityTransform` original presupunea Y-up în spațiul pixel, dar row-ul imaginii merge în jos. Rezultatul: matricea fitată avea reflexie inversă.
**Fix:** model rescris cu y-flip explicit: `X = a·col + b·row + tx`, `Y = b·col − a·row + ty` (al doilea rând al matricei e reflexie `(b, −a)`, nu rotație pură `(b, a)`). GeoTransform corespunzător: `[c, a, b, f, d, e]` cu `e = -a_p` → GT[5] negativ → north scade cu row crescător (north-up corect).

### 7.6 Bounds X/Y swapped
**Simptom:** după prima încercare similarity, bounds-ul ieșea `[524K, 664K, 525K, 666K]` în loc de `[664K, 524K, 666K, 525K]` (X/Y inversate).
**Cauză:** VRT scria `<SRS>EPSG:3844</SRS>`; GDAL respectă axa oficială EPSG (X=north, Y=east) iar restul aplicației folosește convenția proj4 (X=east, Y=north).
**Fix:** `STEREO70_PROJ4` (string proj4 complet) folosit în VRT și ca `-t_srs` la gdalwarp în loc de codul EPSG. Convenția GIS tradițională uniformă în tot stack-ul.

### 7.7 Preview JPEG cu margins negre
**Simptom:** preview-ul JPG generat de RasterPreviewer drop-a alpha (`-b 1 -b 2 -b 3`) → zonele transparente (pixeli RGB=0,0,0 cu alpha=0 puși de gdalwarp) deveneau negru solid în JPEG.
**Fix:** parametru `preserve_alpha: true` la `to_web_preview` → forțează PNG (păstrează alpha, marginile rămân transparente). Apelat din `finalize_warp!` cu `max_dim: 4000` pentru file size acceptabil (~4MB).

### 7.8 Plan delete blocat de redirect
**Simptom:** ștergerea planului din UI răspundea cu 404.
**Fix:** controller `destroy` returnează `redirect_to gis_georef_plans_path, status: :see_other` pentru HTML (303 = method change OK după DELETE).

---

## 8. Funcționalitate „ascunde fundalul alb"

**Cerință:** „Se poate introduce posibilitatea ca să fie vizibil doar ceea ce este scris/desenat iar fundalul să fie eliminat. Trebuie inactivate benzile de fundal de culoare albă."

**Fișiere modificate:**

- `db/migrate/20260511210001_add_bg_transparent_to_gis_user_layer_prefs.rb` — coloană bool nouă (default nil).
- `app/models/gis_user_layer_pref.rb` — `georef_plan_defaults` setează `bg_transparent: true` (default ON pentru raster — pentru scanări cadastrale fundalul alb e zgomot, vrei doar liniile peste parcele).
- `app/javascript/controllers/harta_map_controller.js`
  - `_loadKeyed(image, src)` — procesează imaginea client-side: încarcă PNG/JPEG în `<Image>`, desenează pe `<canvas>`, parcurge `imageData.data` și pune `alpha=0` pentru pixelii cu R,G,B toți ≥230 (threshold ridicat acoperă scanări ușor îngălbenite + anti-aliasing pe muchii); `canvas.toBlob()` → `URL.createObjectURL` → set ca src pe image-ul OL.
  - `applyLayerConfig` — toggle `bg_transparent` recreează sursa via `layer.setSource(_makeGeorefSource(...))`. Reversibil instant, fără regenerare server-side.
- `app/javascript/controllers/layer_manager_controller.js` — checkbox „Ascunde fundalul alb (păstrează doar liniile/textul)" în props-ul layer-ului raster; `changeBgTransparent` action.

---

## Sumar fișiere atinse — sesiunea 11 mai (partea 2: georef)

```
# Migrări (5)
db/migrate/20260511190001_enable_postgis_raster.rb
db/migrate/20260511190002_create_gis_georef_plans.rb
db/migrate/20260511190003_create_gis_georef_control_points.rb
db/migrate/20260511190004_create_active_storage_tables.active_storage.rb
db/migrate/20260511200001_fix_gis_gcp_ordinals.rb
db/migrate/20260511210001_add_bg_transparent_to_gis_user_layer_prefs.rb

# Modele (3)
app/models/gis_georef_plan.rb
app/models/gis_georef_control_point.rb
app/models/gis_user_layer_pref.rb              # extins cu chei georef_plan_<id> + bg_transparent

# Controllere (3)
app/controllers/gis/georef_plans_controller.rb
app/controllers/gis/georef_control_points_controller.rb
app/controllers/gis/layer_prefs_controller.rb  # extins cu pref_params bg_transparent + valid_key? dinamic

# Servicii (4)
app/services/gis/affine_transform.rb
app/services/gis/similarity_transform.rb
app/services/gis/raster_previewer.rb
app/services/gis/raster_warper.rb

# Frontend (3)
app/javascript/controllers/georef_editor_controller.js
app/javascript/controllers/harta_map_controller.js          # extensii: _loadGeorefPlans, _addGeorefLayer, _loadKeyed
app/javascript/controllers/layer_manager_controller.js      # extensii: raster category, bg_transparent toggle

# Views (3)
app/views/gis/georef_plans/index.html.erb
app/views/gis/georef_plans/new.html.erb
app/views/gis/georef_plans/edit.html.erb

# Rute
config/routes.rb
```

**Schema e-CAD existentă: neatinsă. Toate tabelele noi au prefix `gis_`.**

---

# SESIUNEA 2026‑05‑11 (partea 3) — Dev shared owner + selecție multiplă (box / poligon)

## 1. Owner token partajat în development

**Context:** planurile georeferențiate + preferințele Layer Manager + grupurile de layere sunt scoped pe `owner_token` (cookie semnat per browser). În dezvoltare, două browsere (Safari + Chrome) vedeau seturi diferite — Chrome arăta gol fiindcă plansurile fuseseră încărcate din Safari.

**Decizie:** în `Rails.env.development?` se folosește `@owner_token = "dev-shared"` în toate cele 4 controllere care îl populează. Producția rămâne neatinsă — cookie semnat per browser, exact ca înainte.

**Fișiere modificate:**

- `app/controllers/gis/georef_plans_controller.rb` — guard la `Rails.env.development?` în `ensure_owner_token`.
- `app/controllers/gis/georef_control_points_controller.rb` — idem.
- `app/controllers/gis/layer_groups_controller.rb` — idem.
- `app/controllers/gis/layer_prefs_controller.rb` — idem.

**Migrare date (one‑off):** UPDATE-uri pe `gis_georef_plans`, `gis_user_layer_prefs`, `gis_user_layer_groups` → `owner_token = "dev-shared"`. Conflict pe unique `(owner_token, layer_key)` în `gis_user_layer_prefs` rezolvat prin păstrarea celui mai recent rând per `layer_key` și ștergerea duplicatelor. Operațiunea s-a făcut cu `bin/rails runner`, NU prin migrare (n-ar trebui să ruleze în prod).

---

## 2. Selecție multiplă pe hartă + ștergere în bloc

**Cerință:** „este necesar să existe posibilitatea unei acțiuni de selecție multiplă a geometriilor folosind mouse pe hartă și apoi acestea să se poată șterge în bloc".

**Design:**

- Buton toggle vizibil **🔲 Selecție multiplă** în secțiunea „Acțiuni" a panoului `/harta`.
- Când e activ: click pe poligon = toggle in/out, **Shift+drag** = box-select (convenție GIS standard, nu intră în conflict cu pan).
- Buton secundar **🗑 Șterge selecția (N)** care apare dinamic (hidden când N=0 sau modul e off); confirm cu breakdown („3 parcele + 1 clădire") apoi DELETE-uri paralele via `Promise.all` cu un singur `fetch` per feature.
- Overlay portocaliu (`#f97316`, fill 0.20, stroke 3px) pentru toate poligoanele selectate, layer dedicat `zIndex: 998` (sub overlay-ul single-select 999).

**Fișiere modificate:**

- `app/javascript/controllers/harta_map_controller.js`
  - State: `_multiSelectMode`, `_multiSelected` (Map cu cheie `${kind}-${id}`).
  - Layer overlay creat lazy: `_ensureMultiSelectLayer()`.
  - Interaction box-select: `_ensureDragBox()` cu `ol.interaction.DragBox` + `ol.events.condition.shiftKeyOnly`.
  - Metode publice: `enableMultiSelect()`, `disableMultiSelect()`, `clearMultiSelection()`, `getMultiSelection()`.
  - Pe `singleclick`: dacă modul e activ → `_toggleFeatureInMulti(selected)` (în loc de `_setSelectedFeature`), popup-ul info se închide.
  - Pe `boxend`: `_selectFeaturesInExtent(extent)` iterează `parcelLayer` + `cladiriLayer` și adaugă orice feature din extent.
  - Evenimente noi: `harta-map:multi-select-mode`, `harta-map:multi-selection-changed` (cu `{ count, items }`).
- `app/javascript/controllers/digitizare_controller.js`
  - Targets noi: `btnMultiSelect`, `btnDeleteMulti`, `multiSelectInfo`.
  - Listenere pentru cele 2 evenimente noi.
  - Action `toggleMultiSelect`: flip pe mod în harta-map.
  - Action `deleteMultiSelected`: confirm cu breakdown → `Promise.all` cu DELETE pe `/parcele_cadastrale/:id` / `/cladiri_cadastrale/:id` → reload layerele afectate → status `ok` / `warn`.
  - Render dinamic: numărul în textul butonului `🗑 Șterge selecția (N)`, badge separat sub status bar.
- `app/views/harta/index.html.erb` — 2 butoane noi în secțiunea „Acțiuni" + `<div data-digitizare-target="multiSelectInfo">` pentru badge.

---

## 3. Selecție prin poligon neregulat (lasso click‑to‑draw)

**Cerință:** „să fie și prin selecție cu poligon neregulat".

**Design:**

- Buton suplimentar **🔷 Selecție poligon** care lansează un `ol.interaction.Draw type:"Polygon"` cu stil portocaliu dashed. Click adaugă vertex, dublu‑click închide, **Esc** anulează.
- La `drawend` → intersecție reală cu **JSTS** (`jsts.io.OL3Parser` + `intersects()`), NU doar bounding box. O parcelă în formă de L nu va fi luată decât dacă desenul tău o atinge real.
- Auto‑activează modul multi‑select dacă nu e deja pornit — un singur click utilizator.
- Selecția pe poligon e **aditivă** la cea existentă — poți combina box‑drag, click‑toggle și N poligoane.

**Fișiere modificate:**

- `app/javascript/controllers/harta_map_controller.js`
  - `startPolygonSelect()` / `_endPolygonSelect()` — creează/atașează draw interaction + layer overlay portocaliu dashed (`zIndex: 997`), keydown global pentru Esc.
  - `_selectFeaturesByPolygon(olPolygon)` — pre‑filtrează cu `forEachFeatureIntersectingExtent` (bbox cheap), apoi confirmă cu JSTS `intersects()`. Fallback la bbox dacă JSTS lipsește.
  - `_getJstsParser()` — singleton; `parser.inject(ol.geom.Point, LineString, LinearRing, Polygon, MultiPoint, MultiLineString, MultiPolygon)`.
  - Eveniment nou: `harta-map:polygon-select-mode`.
  - `disableMultiSelect()` curăță și polygon draw activ.
- `app/javascript/controllers/digitizare_controller.js`
  - Target nou: `btnPolygonSelect`.
  - Action `startPolygonSelect` + listener `_onPolygonSelectMode` (pentru aria‑pressed + status hint).
- `app/views/harta/index.html.erb` — buton „🔷 Selecție poligon" lângă „🔲 Selecție multiplă".

---

## Sumar fișiere atinse — sesiunea 11 mai (partea 3)

```
# Backend (4 controllere — guard dev pe ensure_owner_token)
app/controllers/gis/georef_plans_controller.rb
app/controllers/gis/georef_control_points_controller.rb
app/controllers/gis/layer_groups_controller.rb
app/controllers/gis/layer_prefs_controller.rb

# Frontend (2 controllere Stimulus)
app/javascript/controllers/harta_map_controller.js     # multi-select + box-select + polygon-select
app/javascript/controllers/digitizare_controller.js    # actions + listenere + bulk delete

# View
app/views/harta/index.html.erb                          # 3 butoane noi în secțiunea Acțiuni
```

**Schema e-CAD existentă: neatinsă.**
