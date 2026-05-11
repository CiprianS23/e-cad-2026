# Ghid de utilizare — Funcționalități GIS noi

> Manual rapid pentru funcționalitățile adăugate în modulul GIS al aplicației e‑CAD: import multi‑format, export pe zonă, click‑to‑zoom, audit dinamic, vizibilitate etichete, georeferențiere planuri vechi, selecție multiplă + ștergere în bloc.
> Versiune: 2026‑05‑11 (partea 3)

---

## Cuprins

1. [Import fișiere (DXF / KML / GPKG)](#1-import-fișiere-dxf--kml--gpkg)
2. [Export pe zonă selectată (DXF / KML / GPKG)](#2-export-pe-zonă-selectată-dxf--kml--gpkg)
3. [Click pe poligon = zoom contextual](#3-click-pe-poligon--zoom-contextual)
4. [Verificare topologie dinamică](#4-verificare-topologie-dinamică)
5. [Vizibilitate etichete](#5-vizibilitate-etichete)
6. [Limita UAT pe hartă](#6-limita-uat-pe-hartă)
7. [Hartă OSM când MapProxy nu rulează](#7-hartă-osm-când-mapproxy-nu-rulează)
8. [Georeferențiere planuri vechi](#8-georeferențiere-planuri-vechi)
9. [Layer Manager — controale pentru planuri raster](#9-layer-manager--controale-pentru-planuri-raster)
10. [Selecție multiplă și ștergere în bloc](#10-selecție-multiplă-și-ștergere-în-bloc)

---

## 1. Import fișiere (DXF / KML / GPKG)

Panoul lateral → secțiunea **Import**.

**Pași:**

1. Apasă **📥 Import fișier (DXF / KML / GPKG)** și alege un fișier `.dxf`, `.kml` sau `.gpkg`.
2. Sistemul detectează automat formatul:
   - **DXF** este parsat **direct în browser** (fără upload — rapid).
   - **KML / GPKG** sunt urcate la server, unde `ogr2ogr` (GDAL) le convertește la GeoJSON în EPSG:3844.
3. Apare un tabel cu **layerele detectate** și o coloană "Mapează la":
   - **Parcele** — poligoanele devin `ParcelaCadastrala` (cu auto‑numerotare `DXF-YYYYMMDD-HHMMSS-N`).
   - **Clădiri** — devin `CladireCadastrala`.
   - **Sectoare** — momentan ignorate (rezervat pentru extindere viitoare).
   - **Ignoră** — exclus din import.
4. Completează default‑urile (Categorie folosință, Județ, Localitate) — aplicate doar pentru parcele.
5. Apasă **✓ Importă**.

**Validări automate la import:** fiecare poligon trece prin validările modelului (`geom_topologic_valid`, `nu_se_suprapune_cu_alte_*`, `geom_nu_e_duplicat`, `nu_traverseaza_mai_multe_parcele` pentru clădiri). Cele care eșuează sunt **respinse** și raportate în rezultat.

**Notă:** ogr2ogr (GDAL) trebuie să fie instalat pe serverul Rails pentru import KML/GPKG. Pe macOS: `brew install gdal`. Verificare: `which ogr2ogr`.

---

## 2. Export pe zonă selectată (DXF / KML / GPKG)

Panoul lateral → secțiunea **Export**.

**Pași:**

1. Alege modul de selecție:
   - **▭ Dreptunghi** — click + drag pe hartă pentru a desena un dreptunghi.
   - **✏️ Poligon** — click pentru fiecare vertex, **dublu‑click** pentru a închide poligonul (formă neregulată).
2. Zona apare conturată în verde‑deschis întrerupt; etichetă cu suprafața și vertecșii sub butoane.
3. Alege formatul: **DXF**, **KML**, sau **GPKG**.
4. Bifează ce layere se exportă: **Parcele** și/sau **Clădiri**.
5. Apasă **⬇ Exportă**.
6. Fișierul se descarcă automat: `export_YYYYMMDD_HHMMSS.<ext>`.

**Reguli de selecție:**

- Sunt incluse **toate** parcele / clădirile care sunt **intersectate** SAU **complet conținute** de poligonul de selecție (operatorul spațial folosit este `ST_Intersects`).
- Coordonatele rămân în EPSG:3844 (Stereo70) pentru DXF; KML și GPKG conțin geometria în WGS84.

**Etichete în export:**

| Format | Conținut etichetă |
|---|---|
| **DXF** | Entități TEXT pe layere `PARCELE_TEXT` / `CLADIRI_TEXT`: nr cadastral pe rândul de sus, "N mp" pe rândul de jos, centrate pe interiorul poligonului. |
| **KML** | `<name>` = nr cadastral (vizibil ca etichetă în Google Earth), `<description>` cu suprafața, plus `<ExtendedData>` cu toate atributele. |
| **GPKG** | Generat din KML prin `ogr2ogr` → moștenește automat toate atributele. |

**Curățare:** apasă **✕ Curăță** pentru a șterge zona selectată și a începe din nou.

---

## 3. Click pe poligon = zoom contextual

Click oriunde într‑o parcelă sau clădire de pe hartă →

- Se afișează popup‑ul cu detalii (nr cadastral, categorie, proprietar etc.).
- Poligonul devine selectat (highlight) → pot fi pornite edit/delete din panoul de acțiuni.
- **Harta face zoom animat (~400 ms)** pe regiunea poligonului — extent‑ul poligonului este lărgit cu factor **×5** față de centroid, deci poligonul ocupă ~20 % din viewport iar zona din jur rămâne vizibilă.
- Pentru entități foarte mici (ex. clădire de 5×5 m), un minim de 5 m pe fiecare jumătate previne zoom‑in excesiv.

**Pentru reglarea factorului de zoom:** dacă vrei zoom mai aproape (poligonul mai mare), modifică în `app/javascript/controllers/harta_map_controller.js` constanta `k` din metoda `_zoomToFeature`:

- `k = 3` — zoom mai aproape (~33 % din viewport)
- `k = 5` — implicit (~20 %)
- `k = 10` — context mai larg (~10 %)

---

## 4. Verificare topologie dinamică

Panoul lateral → secțiunea **Topologie** → **🔍 Scanează erori**.

**Flux:**

1. Server‑ul rulează auditul global (overlap parcele, overlap clădiri, sliver, vertex‑off, clădiri multi‑parcelă, plus CGXML).
2. Erorile sunt afișate ca **straturi colorate pe hartă** (cu severitate categorisită) + **listă** în panou.
3. **NOU:** lista se actualizează automat la fiecare **pan / zoom** al hărții — afișează doar erorile a căror geometrie intersectează viewport‑ul curent.
4. Header‑ul listei: "**N probleme vizibile** (M ascunse — în afara viewport)".

**Acțiuni pe item:**

- **🔎** — zoom direct pe eroarea respectivă.
- Dacă zoom‑in într‑o zonă fără erori, mesaj: "0 probleme în viewport (din N total)" cu sugestia de a face zoom‑out sau pan.

**Curăță audit:** butonul **✕ Curăță** șterge straturile, lista și listenerul de filtrare.

---

## 5. Vizibilitate etichete

Etichetele (nr cadastral + suprafață în mp) sunt afișate pentru parcele, clădiri și imobile CGXML.

**Regulă:** etichetele apar **doar de la scara 1:10000 înspre zoom‑in** (sub 2.645 m/pixel). La scări mai mari (zoom‑out), etichetele dispar automat pentru a evita aglomerarea hărții.

**Tehnic:** pragul e configurat în `app/javascript/controllers/harta_map_controller.js`:

```js
const LABEL_MAX_RESOLUTION         = 2.645   // ≈ scara 1:10 000
const LABEL_MAX_RESOLUTION_CLADIRI = 2.645   // ≈ scara 1:10 000
```

Formula de conversie (DPI 96, monitor standard): `scale ≈ resolution × 3779.5`.

| Scara dorită | Rezoluție prag (m/px) |
|---|---|
| 1:5 000 | 1.32 |
| 1:10 000 | 2.645 (implicit) |
| 1:20 000 | 5.29 |
| 1:50 000 | 13.23 |

Schimbă valoarea și reîncarcă pagina pentru a tara altfel.

**Etichetele se repoziționează automat** în viewport când poligonul iese parțial din ecran (algoritm `_computeLabelPosition` → punct interior dacă e vizibil, altfel centrul intersecției bbox).

---

## 6. Limita UAT pe hartă

La încărcarea hărții, sunt afișate ca **contur violet întrerupt** doar UAT‑urile care **conțin efectiv parcele sau clădiri** din baza de date.

**Tehnic:** endpoint‑ul `/uat_boundaries/geojson` (fără parametri) returnează UAT‑urile filtrate via:

```sql
WHERE EXISTS (SELECT 1 FROM parcele_cadastrale p
              WHERE ST_Intersects(u.geom, p.geom))
   OR EXISTS (SELECT 1 FROM cladiri_cadastrale c
              WHERE ST_Intersects(u.geom, c.geom))
```

**Moduri alternative ale endpoint‑ului:**

| Query | Comportament |
|---|---|
| (fără params) | UAT‑uri cu geometrii reale (default — recomandat) |
| `?lat=&lng=` | UAT‑ul care conține un punct WGS84 (legacy) |
| `?all=1` | Toate cele ~3 186 UAT‑uri din România (~1.6 MB, fallback) |

Bifează / debifează **Limite UAT** din legenda de straturi pentru a comuta vizibilitatea.

---

## 7. Hartă OSM când MapProxy nu rulează

În mod normal, harta de bază OSM și ortofotoplanul ANCPI sunt servite prin **MapProxy** pe portul 8080 (configurat în `app/views/harta/index.html.erb`: `data-harta-map-mapproxy-url-value`).

**Dacă MapProxy nu rulează:**

- La primul tile eșuat (`tileloaderror`), aplicația **comută automat** pe `ol.source.OSM()` standard (Web Mercator EPSG:3857, reproiectat de OpenLayers la EPSG:3844).
- Calitatea e ușor mai slabă (reproiectare client‑side), dar funcționalitatea e completă.
- În consola browser apare: `MapProxy indisponibil — fallback OSM 3857 (reproject).`

**Pornire MapProxy (opțional):**

```bash
cd mapproxy/mapproxy/
mapproxy-util serve-develop mapproxy.yaml --bind 0.0.0.0:8080
```

Reîncarcă pagina după ce MapProxy e online pentru a folosi din nou tile‑urile native Stereo70.

---

## 8. Georeferențiere planuri vechi

Acces: meniu → **Planuri georef** sau direct `/gis/georef_plans`.

Permite încărcarea unei imagini cadastrale scanate (PDF / TIFF / PNG / JPG), plasarea de puncte de control (GCP) pe imagine ↔ hartă reală, și producerea unui GeoTIFF georeferențiat în Stereo70. Planurile finalizate apar automat ca overlay pe `/harta`.

### 8.1 Upload plan

1. Apasă **+ Plan nou**.
2. Completează **Nume** (obligatoriu — ex. „BERESTI cadastral 1985") și opțional **Descriere**.
3. Selectează fișierul (`.tif`/`.tiff`/`.pdf`/`.png`/`.jpg`). TIFF/PDF mari (>50 MB) sunt acceptate dar generarea preview-ului poate dura câteva secunde.
4. Apasă **Salvează**.

În fundal, sistemul:
- Citește dimensiunile reale (W × H) prin `gdalinfo` și le salvează în DB.
- Generează preview JPEG/PNG (`raster_preview_file`) la max 6000px pe latura lungă — afișabil în browser; pentru sursele Palette/Indexed face `-expand rgb`.
- Te redirecționează la ecranul de georeferențiere.

### 8.2 Plasare GCP-uri (ecran dual-viewport)

Ecranul are două panouri side-by-side:

**Panou stânga — imaginea sursă** (în coordonate pixel)
- Zoom cu wheel mouse, pan cu drag.
- Rotire vizuală (butoane ±90° + slider fin -180..180°) — utilă când planul a fost scanat orientat altfel decât nordul; rotația e doar afișaj, coords pixel rămân autoritare.
- Click oriunde pe imagine → marker galben „pending" cu numărul ordinal viitor.

**Panou dreapta — harta de referință** (în Stereo70)
- Base layers: OSM, Google Satellite/Hybrid, Esri World Imagery, Ortofoto ANCPI (via MapProxy).
- Layere overlay: limite UAT, parcele cadastrale, clădiri, CGXML (toggle individual).
- Grid Stereo70 1:5000 cu spațiere configurabilă (500 / 1000 / 2000 / 5000 m) — util pentru planuri vechi cu repere de grid trasate.
- După ce ai click pe sursă (există marker pending), click pe referință → GCP-ul se salvează cu pixel ↔ world.

**Snap inteligent pe referință** (priority în ordine):
1. **Vertex** — dacă există un colț de parcelă/clădire/UAT/CGXML în limita ~15 px de cursor → snap exact la acel colț. E comportamentul corect pentru georef: reperele sunt colțuri identificabile pe ambele planuri.
2. **Intersecție grid Stereo70** — dacă gridul e vizibil și cursorul e în limita `spacing/4` de o intersecție.
3. **Click direct** — fallback, când nu există vertex sau grid în apropiere.

Sursa folosită apare în diag bar: „GCP: vertex parcelă (snap) → (665490.86, 524804.12)".

**Coordonate manuale**: în sidebar → secțiunea **Coordonate manuale (Stereo70)** poți introduce direct X (E) și Y (N) — util pentru repere cu coordonate cunoscute (de ex. cele marcate explicit pe planul scanat).

**Validări automate**:
- GCP cu world identic cu un GCP existent (tol 1 cm) e respins server-side (gdalwarp ar eșua „Transform is not solvable").
- Server-ul asignează ordinal automat — clientul nu trimite ordinal.

**Recomandare**: 3-6 GCP-uri distribuite pe toate cele 4 colțuri ale planului, NU coliniare. Mai multe GCP-uri îmbunătățesc statistic fitarea (RMS).

### 8.3 Preview rapid (afină)

Buton **▶ Recalculează (preview)**: rulează `Gis::AffineTransform.from_points` (least-squares, 6 parametri) → salvează parametri în `transform_params` + RMS. Imaginea NU e încă warped fizic; doar coords colțurilor sunt calculate, suficient pentru afișare aproximativă pe harta principală.

Util pentru a verifica rapid alinierea înainte de Finalize (care e mai lent).

### 8.4 Finalize (gdalwarp + GeoTIFF)

Dropdown **Metodă de transformare**:

| Opțiune | DOF | Când o folosești |
|---|---|---|
| **Similitudine** (default) | 4 | Plan cadastral scanat curat — rotire + scalare uniformă fără distorsiuni interne. Minim 2 GCP-uri. |
| Afină (ordin 1) | 6 | Plan ușor deformat sau cu calibrare scanner inconsecventă (axe X/Y la scale diferite). Minim 3 GCP-uri. |
| Polinomială ordin 2 | — | Plan pe suport hârtie ondulat / cu distorsiuni curbate locale. Minim 6 GCP-uri. |
| Polinomială ordin 3 | — | Distorsiuni puternice. Minim 10 GCP-uri. |
| TPS (thin-plate spline) | — | Fit exact prin fiecare GCP — folosit doar când vrei zero deviație la GCP-uri (acceptă „valuri" între ele). Minim 3 GCP-uri. |

Apasă **✓ Finalize (gdalwarp)**:
1. (Doar pentru palette indexed) `gdal_translate -expand rgba` — convertește sursa la RGBA înainte de resample, altfel bilinear interpolează indecșii paletei = preview negru.
2. Aplică metoda aleasă: pentru similitudine se scrie un VRT cu GeoTransform calculat din modelul Helmert, pentru polinom se folosește pipeline-ul nativ GDAL (gdal_translate -gcp → gdalwarp -order N).
3. `gdalwarp -t_srs <proj4_stereo70> -r bilinear -dstalpha -co COMPRESS=LZW -co TILED=YES -co BIGTIFF=IF_SAFER` → GeoTIFF RGBA optimizat (LZW reduce 693MB → 17-52MB).
4. `gdaladdo -r average 2 4 8 16 32` → 5 niveluri de piramide interne, utile la deschiderea în QGIS/ArcGIS.
5. Generează preview PNG cu alpha pentru afișarea în browser (`warped_preview_file`, max 4000 px latura lungă).
6. Setează `state: finalized`, `transform_params: {a, b, c, d, e, f, warp_bounds_3844, warp_method, warp_width, warp_height}`.

După succes, planul apare imediat pe `/harta` ca image overlay (vezi §9).

### 8.5 Cum aleg GCP-uri bune

**Repere ideale** (colțuri identificabile pe AMBELE planuri):
- Intersecții de drumuri / străzi.
- Colțuri de clădiri vizibile pe ortofoto + marcate pe planul vechi.
- Capete de aliniamente (limite de proprietate stabile).
- Puncte topografice / borne cadastrale dacă sunt vizibile pe planul scanat.
- Intersecții ale gridului 1:5000 dacă planul are gridul trasat explicit.

**De evitat**:
- Centroizi de parcele / clădiri (ambigui, depend de geometria poligonului).
- Marginea planului scanat (poate fi tăiată / deformată la scanare).
- Detalii efemere (vegetație, vehicule).

**Distribuție**: încearcă să acoperi toate 4 colțuri + 1-2 puncte interioare. Toate aliniate = transformare degenerată (gdalwarp eșuează).

### 8.6 Workflow tipic (5 min)

1. Upload TIFF/PDF.
2. Plasează 4-6 GCP-uri pe colțuri de drumuri/clădiri (vertex snap face treaba ușoară).
3. **▶ Recalculează (preview)** — verifică RMS < ~1-3 m și că planul e poziționat corect cu afina rapidă.
4. **✓ Finalize** cu **Similitudine** (default).
5. Mergi la `/harta` — planul apare ca overlay; toggle vizibilitate / opacitate / fundal alb din Layer Manager.

---

## 9. Layer Manager — controale pentru planuri raster

Planurile finalizate apar automat ca rânduri în Layer Manager (panoul de stânga din `/harta`), cu eticheta **„Plan raster: <nume>"**.

Controale disponibile pentru fiecare plan raster:

- **👁 Vizibilitate** — afișează/ascunde planul.
- **🔒 Lock** — implicit blocat (rasterele nu se editează direct; protejează împotriva interacțiunilor accidentale).
- **Slider opacitate** — 0-100% (default 100%; reduce când vrei să vezi parcelele cadastrale prin plan).
- **Checkbox „Ascunde fundalul alb"** — eliminare client-side a pixelilor albi (R,G,B toți ≥ 230 → alpha=0). Bifat default pentru rasteri — pe scanările cadastrale fundalul alb e zgomot, vrei să vezi doar liniile/textul peste parcele.
- **⌖ Zoom la layer** — zoom + fit pe bounding box-ul planului.
- **Drag & drop** — reordonează stiva de layere (sus = z-index mai mare).

**Threshold-ul „fundal alb" (T=230)** e fixat în cod. Acoperă scanări cu hârtie ușor îngălbenită + anti-aliasing pe muchii. Dacă pe scanările tale:
- Prea mult din desen dispare → e nevoie de threshold mai sus (240/245).
- Rămân pete albicioase → threshold mai jos (220).

Pentru a-l face configurabil cu slider per plan, deschide ticket (nu e implementat încă).

**Notă privind performanța:** procesarea pixel-cu-pixel a unui PNG de 4 MB (~27 MP) durează ~200-500 ms one-time la prima încărcare. După, browser-ul afișează direct canvas-ul procesat — fără overhead.

---

## 10. Selecție multiplă și ștergere în bloc

Pentru a șterge mai multe parcele sau clădiri într‑o singură operație. Sunt suportate **trei moduri de selecție** care pot fi combinate (sunt aditive).

### 10.1 Activare

În panoul `/harta` → secțiunea **Acțiuni**:

- **🔲 Selecție multiplă** — buton toggle. Click pentru a intra în mod; click din nou pentru a ieși și curăța selecția.
- Când modul e activ:
  - popup‑urile info pe click sunt dezactivate (nu deranjează selecția),
  - apare un badge portocaliu „N selectate" sub status bar,
  - butonul **🗑 Șterge selecția (N)** devine vizibil și își afișează contorul live.

### 10.2 Cele trei moduri de selecție

**A. Click pe poligoane (toggle individual)**
- Click pe o parcelă/clădire → o adaugă în selecție (contur portocaliu).
- Re‑click pe aceeași → o scoate.
- Util pentru selecție precisă a câtorva poligoane neînvecinate.

**B. Box‑select (Shift+drag)**
- Ține apăsat **Shift**, drag pe hartă pentru a desena un dreptunghi.
- La eliberarea mouse‑ului, toate parcelele/clădirile care **intersectează** dreptunghiul se adaugă.
- Util pentru zone compacte.

**C. Selecție pe poligon neregulat (lasso click‑to‑draw)**
- Click pe butonul **🔷 Selecție poligon** (intri automat și în mod selecție multiplă, dacă nu erai).
- Click pe fiecare vertex al poligonului de selecție.
- **Dublu‑click** închide poligonul → toate features‑urile care intersectează real poligonul se adaugă.
- **Esc** anulează desenul în curs (fără efect asupra selecției deja făcute).
- Intersecția se face cu **JSTS `intersects()`** — nu doar bounding box. O parcelă în formă de L nu se selectează decât dacă desenul tău o atinge geometric.

### 10.3 Ștergere în bloc

1. După ce ai selecția dorită, apasă **🗑 Șterge selecția (N)**.
2. Apare un dialog cu breakdown: `Ștergi 3 parcele + 1 clădire?`.
3. Confirmă → DELETE‑urile sunt trimise în paralel către `/parcele_cadastrale/:id` și `/cladiri_cadastrale/:id`.
4. La final: status `5 geometrii șterse cu succes` (sau breakdown ok/fail dacă vreuna eșuează — ex. constrângere FK).
5. Layerele Parcele și Clădiri se re‑încarcă automat.

### 10.4 Note operaționale

- **Pan‑ul funcționează normal în mod multi‑select** (drag fără Shift = pan, drag cu Shift = box‑select).
- **Layerele invizibile sunt sărite** — dacă ai dezactivat „Clădiri" din Layer Manager, nu poți selecta clădiri (logic — nu le vezi).
- **Selecția nu se păstrează între sesiuni** — nu există persistență server‑side; refresh = selecție goală.
- **Editarea (✎) și ștergerea single (🗑 Șterge) nu sunt afectate** — folosesc selecția single via click normal, când modul multi e off.
- **Ireversibilitate** — DELETE‑ul este definitiv (nu există soft delete). Backupul DB e singura cale de revenire.

---

## Întrebări frecvente

**Î:** Pot importa fișiere cu poligoane care se suprapun cu cele existente?
**R:** Nu prin import normal — validarea de overlap respinge poligonul. Erorile sunt raportate la finalul importului. Dacă vrei să le imporți și apoi să le corectezi în UI, trebuie adăugat un flag "permisiv" (nu e implementat încă — cere‑l explicit).

**Î:** Pot exporta și etichete vectoriale în DXF?
**R:** Da, deja se exportă. Layerele `PARCELE_TEXT` și `CLADIRI_TEXT` conțin entități TEXT (DXF native). Le poți ascunde din AutoCAD/QGIS dacă vrei doar geometriile.

**Î:** De ce nu apare conturul UAT?
**R:** Conturul apare doar pentru UAT‑urile cu geometrii reale în DB. Dacă ai parcele într‑un UAT dar tot nu vezi conturul, verifică:
1. Layer "Limite UAT" e bifat în legendă;
2. Zoom‑out suficient ca limita UAT (până la ~10 km) să fie în viewport;
3. Hard reload (Cmd+Shift+R) pentru a forța reîncărcarea.

**Î:** Pot rula audit topologie automat la fiecare modificare?
**R:** Nu — auditul global e on‑demand (buton 🔍 Scanează erori). Validările per‑record rulează însă **la fiecare save** și împiedică introducerea de erori noi. Pentru audit periodic ar fi nevoie de un job Sidekiq (nu e implementat).

**Î:** Cât de mare poate fi un plan încărcat pentru georeferențiere?
**R:** Testat OK până la ~700 MB TIFF (palette indexed, 15k × 22k pixeli). Limita practică e RAM-ul serverului în timpul `gdalwarp` (necesar ~2-3× dimensiunea sursei). Pentru fișiere mari (>200 MB) procesarea sincronă în controller blochează request-ul 30-60s — la integrarea în prod va trebui mutată în Sidekiq.

**Î:** De ce metoda implicită e Similitudine și nu Afină / Polinomială?
**R:** Pentru scanări cadastrale curate (hârtie plată, scanner liniar), planul are DOAR rotație + scalare uniformă față de sistemul real. Afina (6 DOF) și polinomul (10+ DOF) introduc shear/curbură artificială care „compensează" eroarea de plasare a GCP-urilor (RMS scade dar planul e deformat). Similitudinea (4 DOF) e modelul cel mai onest: dacă RMS-ul e mare cu similitudinea, înseamnă că plasarea GCP-urilor are erori — și pe acelea trebuie verificate, nu mascate.

**Î:** Pot reverti finalize-ul și să plasez GCP-uri noi?
**R:** Da. State-ul plan-ului trece înapoi de la `finalized` la `georeferenced` (sau `draft`) printr-o re-rulare a `Finalize`. Adăugarea/ștergerea de GCP-uri NU șterge automat warped_file vechi — la următorul Finalize se suprascrie.

**Î:** Pot folosi GeoTIFF-ul produs în QGIS / ArcGIS?
**R:** Da. `warped_file` (atașamentul TIFF) e GeoTIFF standard cu SRS Stereo70 + GeoTransform + overviews. Descarcă-l prin link-ul din pagina planului (sau direct URL `/rails/active_storage/blobs/<...>/<nume>_warped.tif`). Browserul nu îl poate afișa direct, dar QGIS îl deschide nativ.
