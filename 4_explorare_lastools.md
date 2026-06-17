# EXPLORARE — LAStools în modulul GIS e‑CAD

## Procesare LiDAR (point cloud) pentru cadastru sistematic

> Document de explorare (NU specificație de implementare). Evaluează dacă și unde
> suita **LAStools** (procesare nori de puncte LiDAR LAS/LAZ) aduce valoare modulului
> GIS de înregistrare sistematică, ce alternative open‑source există și ce ar însemna
> o integrare concretă.
> Sursă evaluată: https://github.com/LAStools/LAStools
> Data: 2026‑06‑17 · Branch: `claude/lastools-exploration-qbwg43`

---

## Cuprins

1. [Concluzie pe scurt (TL;DR)](#1-concluzie-pe-scurt-tldr)
2. [Ce este LAStools](#2-ce-este-lastools)
3. [De ce e relevant pentru e‑CAD — datele ANCPI LAKI](#3-de-ce-e-relevant-pentru-e-cad--datele-ancpi-laki)
4. [Cazuri de utilizare în fluxul cadastral](#4-cazuri-de-utilizare-în-fluxul-cadastral)
5. [Problema licențierii — și alternativa FOSS](#5-problema-licențierii--și-alternativa-foss)
6. [Arhitectură de integrare propusă](#6-arhitectură-de-integrare-propusă)
7. [Layere și tabele noi (schiță, prefix `gis_`)](#7-layere-și-tabele-noi-schiță-prefix-gis_)
8. [Pipeline concret — comenzi](#8-pipeline-concret--comenzi)
9. [Evaluare cost/beneficiu](#9-evaluare-costbeneficiu)
10. [Recomandare și pași următori](#10-recomandare-și-pași-următori)

---

## 1. Concluzie pe scurt (TL;DR)

- **LiDAR NU este nucleul cadastrului sistematic.** Înregistrarea imobilelor este un act
  juridic 2D (limite de proprietate din TP + măsurători stație totală/GPS). Norul de puncte
  nu stabilește hotare juridice. Deci LAStools rămâne un **modul auxiliar**, nu unul critic.
- **Există însă 4–5 câștiguri concrete** acolo unde relieful și înălțimea contează: strat de
  relief (hillshade) ca fundal, **curbe de nivel**, **amprente de clădiri** extrase automat
  (asistă digitizarea — secțiunea 11 a spec‑ului), îmbogățirea cu **cotă Z** a punctelor
  măsurate și indicii de **categorie de folosință** (livadă/pădure) din înălțimea vegetației.
- **Capcana licenței:** majoritatea uneltelor utile din LAStools (`las2dem`, `lasground`,
  `las2iso`, `lasheight`, `lasboundary`) sunt **comerciale**. Pentru un produs de
  **infrastructură publică**, recomandarea este un pipeline **FOSS (PDAL + GDAL)**,
  folosind din LAStools doar componentele open (`laszip`, `las2las`).
- **Recomandare:** explorare cu valoare reală, dar de prioritate **medie‑joasă**. Merită un
  proof‑of‑concept pe datele LAKI III (zona A, DTM 0.5 m) ca **strat de referință**, fără a
  bloca fluxul principal de digitizare.

---

## 2. Ce este LAStools

Suită C++ pentru procesarea norilor de puncte LiDAR (formate **LAS** v1.0–1.4, **LAZ**
comprimat, BIN Terrasolid, ASCII). Trei componente:

| Componentă | Rol | Licență |
|---|---|---|
| **LASzip** | Compresie/decompresie LAS↔LAZ fără pierderi | open (LGPL‑2.1) |
| **LASlib** | API low‑level de citire/scriere | open (LGPL‑2.1) |
| **LAStools (suita)** | ~50 unelte de procesare batch multi‑core | **mixt** (vezi §5) |

Unelte relevante pentru cadastru/topografie/DTM:

```
DESCHISE / GRATUITE
├── laszip        compresie LAS ↔ LAZ
├── las2las       extragere/filtrare/reproiectare/subset
├── las2txt       LAS → ASCII (X Y Z cod) — punte spre importul TXT existent
├── lasmerge      unește mai multe dale
├── lasinfo       sumar conținut fișier (extent, clase, densitate)
├── lasindex      index spațial (.lax) pentru acces rapid pe zonă
└── lasvalidate   conformitate cu specificația ASPRS LAS

LICENȚIATE (comerciale)
├── lasground     clasificare „bare earth" (teren vs. vegetație/clădiri)
├── las2dem       raster DTM/DSM + pantă + hillshade
├── las2iso       curbe de nivel (izolinii)
├── lasheight     înălțime deasupra solului (nDSM)
├── lasgrid       raster min/max/avg pe celulă
├── lasboundary   poligon de contur al norului / al claselor
├── lasclassify   clasificare clădiri + vegetație
└── lastile       împărțire în dale cu buffer
```

---

## 3. De ce e relevant pentru e‑CAD — datele ANCPI LAKI

Argumentul de fond nu e tehnologia, ci **sursa de date**:

```
ANCPI  ──┬──  impune schema CGXML (cerință legală — vezi CLAUDE.md)
         │
         └──  produce DATE LiDAR NAȚIONALE prin programele LAKI II / LAKI III
              ├── LAKI III: ~50.000 km² scanare aeropurtată → DTM + DSM
              ├── Zona A: Caraș‑Severin, Gorj, Mehedinți, Dolj  (DTM 0.5 m integrat)
              ├── Zona B: Suceava, Neamț, Bacău, Vrancea
              └── distribuite prin geoportalul ANCPI
```

Implicația: **aceeași autoritate** care primește livrabilul CGXML produce și norii de puncte /
DTM‑urile. Pentru un UAT aflat în acoperirea LAKI, modulul poate consuma un produs oficial,
gratuit, în **același sistem de proiecție** vizat de aplicație (Stereo70 / EPSG:3844), fără
achiziție proprie de LiDAR. Acoperirea națională uniformă **nu** este însă completă — deci
funcția trebuie tratată ca **opțională, per‑zonă**, exact ca stratul `PLAN_VECHI`.

> Notă importantă: pentru produsele DTM/DSM gata‑rasterizate de ANCPI **nu este nevoie de
> LAStools deloc** — sunt deja GeoTIFF. LAStools devine relevant doar dacă se obține norul de
> puncte **brut** (LAS/LAZ) și trebuie derivate produse proprii (curbe, amprente, nDSM).

---

## 4. Cazuri de utilizare în fluxul cadastral

Ordonate după raport valoare/efort pentru înregistrarea sistematică:

### 4.1 Strat de relief (hillshade) ca fundal — valoare medie, efort mic
DTM → umbrire → GeoTIFF servit ca strat de fundal, analog `ORTOFOTO`/`PLAN_VECHI`. Ajută
specialistul să „citească" terenul (versanți, văi, taluzuri) când ortofotoplanul e ambiguu.

### 4.2 Curbe de nivel — valoare medie, efort mic
`las2dem` + `las2iso` (sau GDAL `gdal_contour` pe DTM) → strat vectorial de izolinii. Util
ca referință topografică și pentru planurile de situație anexate.

### 4.3 Amprente de clădiri extrase automat — valoare mare, efort mediu
Cel mai concret câștig. `lasground` → `lasheight` → filtrare puncte > ~2 m → `lasboundary` →
poligoane de amprentă. Acestea alimentează stratul `CONSTRUCTII` ca **sugestii** de digitizat
(specialistul validează), în spiritul „detectării automate" din §11 al spec‑ului GIS — dar pe
geometrie 3D fiabilă, nu pe pattern‑uri vizuale 2D.

```
NOR LiDAR ─ lasground ─ lasheight ─ filtru Z>2m ─ lasboundary ─► poligoane CONSTRUCTII (sugestii)
                                                                  → specialistul acceptă/respinge
```

### 4.4 Îmbogățirea cu cotă Z a măsurătorilor — valoare medie, efort mic
Importul TXT (spec §8.1) are deja coloana **Z**. Acolo unde lipsește, DTM‑ul poate completa
cota pentru fiecare punct (X,Y) → utilă pentru planuri de situație și verificări de pantă.

### 4.5 Indicii de categorie de folosință — valoare mică‑medie, exploratoriu
Înălțimea vegetației (nDSM = DSM − DTM) distinge orientativ **livadă/pădure** (canopy înalt) de
**arabil/pășune** (canopy ~0). Poate pre‑sugera `categorie folosință` (vezi paleta din §9.4 a
spec‑ului), confirmată de specialist. Sugestie, niciodată decizie automată.

### 4.6 Ce NU rezolvă LiDAR
- **Nu** stabilește hotare juridice (acelea vin din TP + măsurători).
- **Nu** înlocuiește topologia PostGIS (§12 spec).
- **Nu** ajută la fluxul ACTE/proprietari (zona non‑geometrică).

---

## 5. Problema licențierii — și alternativa FOSS

Aproape toate uneltele utile de mai sus (`las2dem`, `lasground`, `las2iso`, `lasheight`,
`lasboundary`) sunt **licențiate comercial** (trial limitat la ~3–5 mil. puncte, cu artefacte
diagonale peste prag). Termenii rapidlasso (producătorul) sunt expliciți:

```
├── educație + evaluare        → GRATUIT
├── trial → ~3–5 mil. puncte   → GRATUIT (peste prag: artefacte vizibile)
└── uz COMERCIAL *și GUVERNAMENTAL*  → LICENȚĂ PLĂTITĂ
```

Punctul critic: **uzul guvernamental necesită licență plătită**. Cadastrul sistematic, derulat
de/pentru UAT‑uri și sub autoritatea ANCPI, este exact „uz guvernamental". Pentru un sistem de
**infrastructură publică, single‑instance, multi‑tenant** (zeci/sute de primării), dependența de
o licență comercială per‑procesare este un risc operațional, bugetar și juridic concret — nu o
chestiune teoretică.

**Recomandare: pipeline FOSS echivalent**, folosind din LAStools doar partea open:

| Nevoie | LAStools (comercial) | Alternativă FOSS |
|---|---|---|
| Citire/scriere LAZ | LASzip ✅ open | **PDAL** / laszip |
| Decompresie/filtrare | `las2las` ✅ open | `las2las` / **PDAL** |
| Clasificare sol | `lasground` 💰 | **PDAL** `filters.smrf` / `filters.pmf` |
| DTM/DSM raster | `las2dem` 💰 | **PDAL** `writers.gdal` + **GDAL** |
| Curbe de nivel | `las2iso` 💰 | **GDAL** `gdal_contour` |
| nDSM (height) | `lasheight` 💰 | **PDAL** `filters.hag_nn` |
| Amprente/contur | `lasboundary` 💰 | **PDAL** `filters.hexbin` / GDAL polygonize |

**GDAL este deja în stack** (CLAUDE/help: `ogr2ogr` se folosește pentru import KML/GPKG).
**PDAL** este complementul natural pentru point cloud și se instalează identic în Docker.

> Concluzie §5: LAStools e excelent pentru prototipare rapidă și ca **referință de corectitudine**,
> dar pentru producție pipeline‑ul ar trebui construit pe **PDAL + GDAL**. LAStools rămâne util
> pentru `laszip`/`las2las` (open) și pentru validare comparativă.

---

## 6. Arhitectură de integrare propusă

Procesarea LiDAR e grea și batch — **nu** se face în request HTTP. Se aliniază cu Sidekiq
(deja în stack, §2.1 spec):

```
┌──────────────────────────────────────────────────────────────────┐
│  INGEST (o singură dată per zonă/UAT)                            │
│  Nor LAS/LAZ (LAKI III sau achiziție) ─► storage (disk/S3)       │
└───────────────┬──────────────────────────────────────────────────┘
                │  Sidekiq job (background, batched pe dale)
                ▼
┌──────────────────────────────────────────────────────────────────┐
│  PROCESARE (PDAL + GDAL; opțional LAStools open pt. laszip)      │
│  ├── reproiectare → EPSG:3844 (Stereo70)                         │
│  ├── clasificare sol (filters.smrf)                              │
│  ├── DTM + DSM (writers.gdal) → GeoTIFF                          │
│  ├── hillshade (gdaldem)        → GeoTIFF                        │
│  ├── curbe nivel (gdal_contour) → GeoJSON/PostGIS                │
│  └── amprente clădiri (hag + polygonize) → GeoJSON/PostGIS       │
└───────────────┬──────────────────────────────────────────────────┘
                ▼
┌──────────────────────────────────────────────────────────────────┐
│  SERVIRE                                                          │
│  ├── Rastere (DTM/hillshade) → MapProxy/GeoServer (ca ORTOFOTO)  │
│  └── Vectori (curbe, amprente) → tabele gis_* → OpenLayers       │
└──────────────────────────────────────────────────────────────────┘
```

Principii respectate (CLAUDE.md): zero modificări la schema e‑CAD; tabele noi cu prefix
`gis_`; produsele LiDAR sunt **straturi de referință opționale**, aplicația tolerează absența
lor (la fel ca lipsa MapProxy → fallback OSM, help §7).

---

## 7. Layere și tabele noi (schiță, prefix `gis_`)

Doar schiță conceptuală — **fără migrări în acest document**.

```
LAYERE noi în panelul de layere (analog tabelului din spec §4.1)
├── RELIEF_LIDAR    (raster hillshade, background, oprit implicit)
├── CURBE_NIVEL     (vector izolinii, gri subțire, oprit implicit)
└── CONSTRUCTII_LIDAR (sugestii amprente, magenta punctat — separate de CONSTRUCTII validate)

TABELE (schiță)
gis_lidar_tile
  ├─ id, comuna_id            (multi‑tenant, ca restul aplicației)
  ├─ extent  geometry(Polygon,3844)
  ├─ sursa   (LAKI3 | achizitie_proprie)
  ├─ densitate_pct, clase (jsonb din lasinfo/pdal info)
  └─ dtm_path, dsm_path, hillshade_path

gis_lidar_contour
  ├─ id, comuna_id
  ├─ cota numeric            (ex. 245.0)
  ├─ geom geometry(LineString,3844)  + index GIST
  └─ tile_id (FK gis_lidar_tile)

gis_lidar_building_hint
  ├─ id, comuna_id
  ├─ geom geometry(Polygon,3844) + index GIST
  ├─ inaltime_medie numeric  (din nDSM)
  ├─ status (sugestie | acceptat | respins)
  └─ cladire_cadastrala_id (FK opțional — completat la acceptare)
```

`gis_lidar_building_hint` se leagă de modelul existent `CladireCadastrala` (vezi jurnal,
sesiunea 2026‑05‑10) doar la acceptarea sugestiei — fără a‑l modifica.

---

## 8. Pipeline concret — comenzi

### 8.1 Varianta LAStools (prototip rapid)

```bash
# 1. info + index
lasinfo  zona.laz
lasindex zona.laz

# 2. clasificare sol + înălțime
lasground_new -i zona.laz -o zona_g.laz
lasheight     -i zona_g.laz -o zona_h.laz -replace_z   # Z := înălțime deasupra solului

# 3. DTM (doar sol) + hillshade
las2dem -i zona_g.laz -keep_class 2 -step 0.5 -hillshade -o dtm_hs.tif

# 4. curbe de nivel la 1 m
las2iso -i zona_g.laz -keep_class 2 -iso_every 1.0 -o curbe.shp

# 5. amprente clădiri (puncte > 2 m deasupra solului)
las2las     -i zona_h.laz -drop_z_below 2.0 -o cladiri_pts.laz
lasboundary -i cladiri_pts.laz -concavity 2 -o cladiri.shp
```

### 8.2 Varianta FOSS recomandată (producție) — PDAL + GDAL

```bash
# 1. reproiectare la Stereo70 + clasificare sol (SMRF) + DTM raster
pdal pipeline dtm.json    # reader.las → filters.reprojection(EPSG:3844)
                          # → filters.smrf → writers.gdal (output_type=idw, res=0.5)

# 2. hillshade din DTM
gdaldem hillshade dtm.tif dtm_hillshade.tif

# 3. curbe de nivel
gdal_contour -a cota -i 1.0 dtm.tif curbe.gpkg

# 4. nDSM (height above ground) + amprente
pdal pipeline hag.json    # filters.hag_nn → writers.gdal (DSM)
gdal_calc.py -A dsm.tif -B dtm.tif --calc="A-B" --outfile=ndsm.tif
# prag > 2m → poligonizare → import în gis_lidar_building_hint
```

Ambele rulează în Docker (Dockerfile existent) ca dependențe de sistem; orchestrate dintr‑un
Sidekiq job pe dale, batched (constrângerea de migrări/joburi batched din CLAUDE.md).

---

## 9. Evaluare cost/beneficiu

```
BENEFICII
├── Strat de relief + curbe de nivel        → context topografic real (efort mic)
├── Amprente clădiri ca sugestii            → accelerează digitizarea CONSTRUCTII
├── Cotă Z pentru puncte fără elevație      → planuri de situație mai complete
├── Sursă oficială gratuită (LAKI) în Stereo70 unde există acoperire
└── Aliniere cu autoritatea (ANCPI) care primește și livrabilul CGXML

COSTURI / RISCURI
├── LiDAR nu e pe drumul critic al înregistrării (juridicul rămâne 2D)
├── Acoperire LAKI parțială → funcție opțională, nu garantată per‑UAT
├── Licență LAStools comercială → necesită pivot pe PDAL+GDAL pt. producție
├── Volume mari de date (nori de puncte) → storage + timp de procesare
└── Dependențe noi de sistem (PDAL) în imaginea Docker

VERDICT: prioritate MEDIE‑JOASĂ. Valoare reală, dar auxiliară. De pus DUPĂ
         consolidarea fluxului principal (digitizare, topologie, export CGXML).
```

---

## 10. Recomandare și pași următori

1. **Proof‑of‑concept restrâns**, fără cod în aplicație: ia o dală LAKI III (zona A) și rulează
   pipeline‑ul §8.2 (PDAL+GDAL) local → produ `dtm_hillshade.tif` + `curbe.gpkg` + un set de
   amprente. Validează vizual peste ortofotoplan în OpenLayers.
2. **Decide sursa de date**: dacă ANCPI livrează deja DTM/DSM raster pentru UAT‑urile țintă,
   atunci LAStools/PDAL devin inutile — se consumă direct GeoTIFF‑urile (mult mai simplu).
   LAStools/PDAL au sens **doar** dacă se pornește de la nor de puncte brut.
3. **Dacă PoC convinge**: implementează ca **strat de referință opțional** (layere
   `RELIEF_LIDAR` / `CURBE_NIVEL`) + un job Sidekiq de ingest, cu tabelele `gis_*` din §7.
   Amprentele rămân **sugestii** revizuite de specialist — niciodată geometrie automată
   acceptată direct (același principiu ca unificarea proprietarilor: decizie umană înregistrată).
4. **Producție = PDAL + GDAL** (FOSS), LAStools păstrat doar pentru `laszip`/`las2las` și ca
   referință de corectitudine.

> Acest document este explorare. Nu modifică schema, nu adaugă migrări și nu atinge fluxul
> existent. Servește ca bază de decizie înainte de a aloca efort de implementare.

---

*Document de explorare · 2026‑06‑17 · Modul GIS e‑CAD*
*Surse: github.com/LAStools/LAStools · rapidlasso.de (product-overview, pricing) · programele ANCPI LAKI II/III · PDAL.io · GDAL.org*
