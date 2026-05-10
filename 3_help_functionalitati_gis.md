# Ghid de utilizare — Funcționalități GIS noi

> Manual rapid pentru funcționalitățile adăugate în modulul GIS al aplicației e‑CAD: import multi‑format, export pe zonă, click‑to‑zoom, audit dinamic, vizibilitate etichete.
> Versiune: 2026‑05‑11

---

## Cuprins

1. [Import fișiere (DXF / KML / GPKG)](#1-import-fișiere-dxf--kml--gpkg)
2. [Export pe zonă selectată (DXF / KML / GPKG)](#2-export-pe-zonă-selectată-dxf--kml--gpkg)
3. [Click pe poligon = zoom contextual](#3-click-pe-poligon--zoom-contextual)
4. [Verificare topologie dinamică](#4-verificare-topologie-dinamică)
5. [Vizibilitate etichete](#5-vizibilitate-etichete)
6. [Limita UAT pe hartă](#6-limita-uat-pe-hartă)
7. [Hartă OSM când MapProxy nu rulează](#7-hartă-osm-când-mapproxy-nu-rulează)

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
