# Point Cloud Tool — Procesare & Potree

Aplicație desktop locală (single-user / echipă) pentru procesarea norilor de
puncte din scanare dronă (DJI Zenmuse L2) sau terestră, vizualizare în Potree și
extragere de features (teren, clădiri, vegetație, linii electrice).

Specificația completă: vezi `CLAUDE.md`.

## Instalare

PDAL + GDAL se instalează cel mai sigur prin conda/mamba:

```bash
mamba create -n pointcloud -c conda-forge python=3.11 pdal python-pdal gdal rasterio shapely
conda activate pointcloud
pip install -r requirements.txt
```

Binare externe în `bin/` (nu sunt în git — se descarcă upstream):
`e57-to-las`, `PotreeConverter`, `CloudCompare`, opțional `e572las`.
Căile se pot suprascrie cu variabile de mediu: `POTREECONVERTER_BIN`,
`CLOUDCOMPARE_BIN`, `E57_TO_LAS_BIN`, `E572LAS_BIN`, `LASINFO_BIN`.

Librăria Potree 2.x (build static oficial) se pune în `potree/`.

## Rulare

```bash
./run.sh          # Linux / macOS
run.bat           # Windows
```

Serverul pornește pe http://localhost:8000 și servește UI-ul cu pași.
UI-ul pornește și fără PDAL/binare instalate — joburile raportează eroare clară
la rulare.

## Flux

```
LAS/LAZ/E57
  → normalize (E57→LAZ, validare header)
  → denoise (outlier + drop noise)
  → reproject → EPSG:3844
  → classify ground (SMRF) + HeightAboveGround
  → features (DTM / CHM / buildings / powerlines)
  → build Potree → viewer (colorat pe Classification) + overlay GeoJSON
```

## API

| Rută | Descriere |
|---|---|
| `POST /api/upload` | multipart las/laz/e57 → `file_id` |
| `POST /api/run/{step}` | `{file_id, params}` → `job_id` |
| `GET /api/jobs/{job_id}` | status / progress / log / result |
| `GET /api/features/{scan_id}` | listă GeoJSON / GeoTIFF |
| `GET /api/scans` | scanuri cu octree Potree |
| `/potree-data/<scan_id>` | octree static |
| `/` | frontend |

Pași (`step`): `normalize`, `denoise`, `reproject`, `classify`, `feature_dtm`,
`feature_chm`, `feature_buildings`, `feature_powerlines`, `potree`.

## Structură

```
pointcloud-tool/
├── backend/        FastAPI + jobs + tools + pipelines
├── frontend/       UI pași + viewer Potree
├── bin/            binare externe (nu în git)
├── potree/         librăria Potree (nu în git)
└── data/           uploads / work / out / potree (nu în git)
```
