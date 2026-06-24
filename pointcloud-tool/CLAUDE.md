# CLAUDE.md — Point Cloud Processing & Potree Viewer

Document de referință pentru dezvoltarea aplicației. Servește ca specificație tehnică
și ca brief pentru implementare asistată (Claude Code).

-----

## 1. Scop

Aplicație **desktop single-user / echipă (rulare locală)** care:

1. Acceptă nori de puncte din scanare dronă (DJI Zenmuse L2) sau scanare terestră,
   în formate **LAS / LAZ / E57**.
1. Execută, printr-o interfață cu pași, comenzi de procesare point-cloud
   (normalizare, denoise, reproiectare, clasificare).
1. Vizualizează rezultatul direct în **Potree**, colorat pe clasificare.
1. Extrage automat **features**: teren (DTM/DEM), clădiri (footprints/plane),
   vegetație (CHM), linii electrice + stâlpi.

Nu este un serviciu web multi-user. Rulează local, pe un singur calculator.

-----

## 2. Decizii fixate

|Aspect                          |Decizie                                                                          |
|--------------------------------|---------------------------------------------------------------------------------|
|Mod de rulare                   |Single-user, local                                                               |
|Sistem de coordonate (SRS țintă)|**EPSG:3844** (Stereo 70 — Dealul Piscului 1970, România)                        |
|Buget unelte                    |Open-source + LAStools **gratuit** (e572las, lasinfo, las2las, lasindex, txt2las)|
|Clasificare sol                 |PDAL `filters.smrf` (NU lasground — e licențiat)                                 |
|Backend                         |Python 3.11+ / FastAPI                                                           |
|Frontend                        |HTML/JS servit static de FastAPI (fără build step la început)                    |
|Viewer                          |Potree 2.x (static)                                                              |
|Conversie octree                |PotreeConverter 2.x (encoding BROTLI)                                            |
|Convertor E57                   |`e57-to-las` (nivalis-studio, open-source) ca implicit; `e572las` fallback       |

### Note de licență (critic)

- **Gratuite în LAStools:** `e572las`, `lasinfo`, `las2las`, `lasindex`, `txt2las`,
  `lasprecision`, `lasdiff`.
- **Licențiate (NU se folosesc):** `lasground`, `lasclassify`, `lasthin` (peste limite),
  `lastile` (peste limite). Toată clasificarea se face cu **PDAL**.

-----

## 3. Arhitectură

Trei straturi:

1. **Frontend (UI)** — selecție fișier, pași de procesare cu parametri editabili,
   butoane Run, panou de status/progres, iframe Potree, overlay features.
1. **Backend (orchestrator)** — FastAPI; primește comenzi, rulează PDAL (binding
   Python) și unelte externe (e57-to-las, CloudCompare CLI, PotreeConverter) ca
   subprocese; gestionează coada de joburi și statusul.
1. **Viewer Potree** — servit static; afișează octree-ul; primește overlay-uri GeoJSON.

```
LAS/LAZ/E57
  → normalizare (E57→LAZ; merge scanări)
  → denoise (outlier) + reproiectare EPSG:3844
  → clasificare sol (SMRF) + HeightAboveGround
  → extragere features (DTM / CHM / clădiri / linii)
  → PotreeConverter → octree
  → Potree viewer (colorat pe Classification) + overlay GeoJSON
```

> Implementarea efectivă a structurii și a pipeline-urilor este descrisă în
> `README.md` și în codul din `backend/`. Acest document rămâne specificația de
> referință; orice abatere intenționată se notează în jurnalul de modificări.

-----

## 4. Structură de proiect

```
pointcloud-tool/
├── CLAUDE.md                 # acest document
├── backend/
│   ├── main.py               # FastAPI app + rutele API + static mounts
│   ├── jobs.py               # coadă joburi, status, progres (in-memory + persist json)
│   ├── tools.py              # wrappers subprocess: e57, CloudCompare, PotreeConverter
│   ├── settings.py           # căi binare, EPSG implicit, directoare
│   ├── workspace.py          # rezolvarea căilor pe scan + înlănțuirea pașilor
│   └── pipelines/
│       ├── normalize.py      # E57→LAZ, merge, validare header
│       ├── denoise.py        # filters.outlier + filters.range (drop noise)
│       ├── reproject.py      # filters.reprojection → EPSG:3844
│       ├── classify_ground.py# filters.smrf + filters.hag_nn
│       ├── to_potree.py      # PotreeConverter wrapper
│       └── features/
│           ├── dtm.py        # sol → GeoTIFF (writers.gdal)
│           ├── chm.py        # vegetație: HAG → raster înălțime
│           ├── buildings.py  # HAG>prag → plane RANSAC (CloudCompare) → footprints
│           └── powerlines.py # clustere liniare HAG mare (PCA) + stâlpi verticali
├── bin/                      # binare externe (NU în git): e57-to-las, PotreeConverter, CloudCompare
├── data/
│   ├── uploads/              # fișiere brute primite
│   ├── work/                 # intermediare (laz pe pași)
│   ├── out/                  # GeoTIFF + GeoJSON features
│   └── potree/               # octree-uri servite static (un folder per scan)
├── frontend/
│   ├── index.html            # UI pași
│   ├── app.js                # logică: upload, run step, polling, overlay
│   ├── viewer.html           # bootstrap Potree + overlay GeoJSON
│   └── style.css
├── potree/                   # librăria Potree (static, build oficial)
├── requirements.txt
└── run.bat / run.sh
```

-----

## 5. Formate de intrare și normalizare

### 5.1 E57

- **PDAL NU citește E57 implicit** (necesită build cu libE57). De aceea E57 se
  convertește **înainte** de pipeline.
- Implicit: `e57-to-las` (nivalis-studio).

  ```
  bin/e57-to-las -p input.e57 -o data/work/ --stations -L 1.4 -T 0
  ```
- Fallback: `e572las -v -i input.e57 -o data/work/raw.laz` (alpha — se validează output-ul).

### 5.2 LAS/LAZ

- Intră direct. Dacă sunt multiple fișiere/stații, se face merge în pipeline.

### 5.3 Validare după normalizare

- `lasinfo` pe rezultat: număr puncte, bbox, SRS prezent/absent, RGB/intensity.
- Dacă SRS lipsește, se cere SRS-ul sursei înainte de reproiectare.

-----

## 6. Pipeline-uri PDAL (specificație)

Parametrii sunt valori de pornire — expuși în UI ca editabili.

### 6.1 Denoise + drop noise class

`filters.outlier` (statistical, mean_k=12, multiplier=2.2) marchează zgomotul ca
Classification 7; `filters.range` cu `Classification![7:7]` îl elimină.

### 6.2 Reproiectare → EPSG:3844

`filters.reprojection` cu `out_srs=EPSG:3844`. Dacă headerul nu are SRS, se adaugă
`in_srs`.

### 6.3 Clasificare sol (SMRF) + HeightAboveGround

`filters.smrf` (scalar=1.2, slope=0.2, threshold=0.45, window=16.0) →
Classification 2 (sol) / 1. `filters.hag_nn` adaugă HeightAboveGround.

-----

## 7. Extragere features (cele 4 clase)

|Feature|Sursă date|Metodă (gratuit)|Output|
|---|---|---|---|
|**DTM/DEM**|Classification=2|`writers.gdal` IDW|GeoTIFF|
|**CHM / vegetație**|HAG (interval)|`writers.gdal` pe HAG|GeoTIFF|
|**Clădiri**|HAG > 2.5m, non-veg|RANSAC plane (CloudCompare) → poligonizare|GeoJSON footprints|
|**Linii electrice + stâlpi**|HAG mare, clustere|`filters.cluster` + PCA liniaritate|GeoJSON linii + puncte|

Detalii pe fiecare feature: §7.1–§7.4 (vezi codul din `backend/pipelines/features/`).

-----

## 8. Conversie Potree

```
bin/PotreeConverter data/work/classified.laz -o data/potree/<scan_id> --encoding BROTLI
```

Un folder per scan. Octree-ul păstrează Classification → colorare în viewer.

-----

## 9. API (FastAPI)

Joburile rulează în background; UI face polling.

```
POST /api/upload                 # multipart; las/laz/e57 → file_id
POST /api/run/{step}             # body { file_id, params } → job_id
GET  /api/jobs/{job_id}          # status: queued|running|done|error, progress, log, result
GET  /api/features/{scan_id}     # listă GeoJSON / GeoTIFF
GET  /api/scans                  # scanuri procesate + folder potree
Static: /potree-data/<scan_id>   # octree
Static: /                        # frontend
```

-----

## 10. Frontend (UI pași)

Coloană de pași secvențiali, fiecare cu parametri editabili + buton Run + status:
Upload → Normalize → Denoise → Reproject → Classify ground → Features → Build Potree.
Overlay features (footprints, linii, stâlpi) se încarcă în Potree ca layer vectorial.
DTM/CHM rămân GeoTIFF descărcabile.

-----

## 11. Mediu de rulare

- **Binare în `bin/`:** `e57-to-las`, `PotreeConverter`, `CloudCompare`, opțional `e572las`.
- **Python:** 3.11+, `pdal`, `fastapi`, `uvicorn`, `python-multipart`, `numpy`,
  `gdal`/`rasterio`, `shapely`.
- Recomandare: PDAL+GDAL prin **conda/mamba**.
- `run.bat`/`run.sh`: pornește `uvicorn backend.main:app` și deschide browserul.

-----

## 12. Riscuri / de validat

1. **E57 → coordonate:** validare bbox după conversie (e572las are bug-uri istorice).
1. **SRS de intrare L2:** confirmă proiecția sursei înainte de reproiectare.
1. **RANSAC clădiri:** calibrare parametri CloudCompare per tip de structură.
1. **Linii electrice:** pragurile HAG/cluster depind de înălțimea de zbor.
1. **Volume mari:** PotreeConverter direct vs. Entwine/EPT — de evaluat.

-----

## 13. Pași următori de implementare

1. Schelet `backend/main.py` + `jobs.py` + `tools.py`.
1. `pipelines/` — normalize, denoise, reproject, classify.
1. `to_potree.py` + verificare viewer.
1. Features pe rând: DTM → CHM → powerlines → buildings.
1. UI: pași + polling + iframe + overlay GeoJSON.
1. Calibrare parametri pe date reale L2 + scanare terestră.
