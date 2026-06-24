"""Clădiri — footprints (CLAUDE.md §7.3).

Strategie pragmatică, complet gratuită:
  1. PDAL: puncte cu HeightAboveGround > prag, Classification ≠ sol; exclude
     clusterele liniare (acelea sunt linii electrice — vezi powerlines.py).
  2. (opțional) CloudCompare RANSAC pentru segmentare plane acoperiș/pereți.
  3. Rasterizare ocupare + vectorizare contur → poligoane footprint.
  4. GeoJSON footprints cu atribute: înălțime medie, suprafață.

Pasul CloudCompare e best-effort (calibrare per structură — CLAUDE.md §12);
poligonizarea finală se face pe grila de ocupare, robustă fără el.
"""
from __future__ import annotations

import json
from collections import defaultdict

import numpy as np

from ... import tools
from ...jobs import Job
from ...settings import settings
from ...workspace import latest_artifact, out_dir, resolve_input, work_path


def run(job: Job, params: dict) -> dict:
    file_id = job.file_id
    if not file_id:
        raise ValueError("feature_buildings: lipsește file_id")

    src = resolve_input(file_id, "feature_buildings") or latest_artifact(file_id)
    if src is None or not src.exists():
        raise FileNotFoundError(f"feature_buildings: intrare inexistentă pentru {file_id}")

    hag_min = float(params.get("hag_min", 2.5))
    resolution = float(params.get("resolution", 0.5))
    min_area = float(params.get("min_area", 8.0))      # m² minim pentru un footprint
    linearity_threshold = float(params.get("linearity_threshold", 0.9))
    use_cloudcompare = bool(params.get("use_cloudcompare", False))

    try:
        import pdal
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError("Binding-ul `pdal` nu e instalat.") from exc

    job.set_progress(10)
    # Candidați + clusterizare (pentru a putea exclude liniile electrice).
    stages = [
        str(src),
        {"type": "filters.range",
         "limits": f"HeightAboveGround[{hag_min}:1000],Classification![2:2]"},
        {"type": "filters.cluster", "min_points": 20, "tolerance": 1.0},
    ]
    pipeline = pdal.Pipeline(json.dumps({"pipeline": stages}))
    pipeline.execute()
    if not pipeline.arrays or len(pipeline.arrays[0]) == 0:
        job.append_log("Niciun punct candidat pentru clădiri.")
        return _write_geojson(file_id, [])

    arr = pipeline.arrays[0]
    job.set_progress(40)

    # Exclude clusterele puternic liniare (linii electrice).
    keep_mask = _drop_linear_clusters(arr, linearity_threshold, job)
    xs = arr["X"][keep_mask].astype(float)
    ys = arr["Y"][keep_mask].astype(float)
    zs = arr["Z"][keep_mask].astype(float)
    if xs.size == 0:
        job.append_log("Toți candidații au fost excluși ca liniari.")
        return _write_geojson(file_id, [])

    # Pasul CloudCompare RANSAC (best-effort).
    if use_cloudcompare:
        candidate_path = work_path(file_id, "buildings_candidate.laz")
        _write_candidate(pdal, src, hag_min, candidate_path, job)
        try:
            tools.cloudcompare_ransac(candidate_path, job=job)
        except tools.ToolError as exc:
            job.append_log(f"CloudCompare indisponibil/eșuat ({exc}); continui cu rasterizarea.")

    job.set_progress(60)
    polygons = _vectorize_footprints(xs, ys, zs, resolution, min_area, job)
    job.append_log(f"{len(polygons)} footprints peste {min_area} m².")
    job.set_progress(90)
    return _write_geojson(file_id, polygons)


def _drop_linear_clusters(arr, linearity_threshold: float, job: Job) -> np.ndarray:
    """Întoarce o mască booleană care păstrează doar punctele din clustere ne-liniare."""
    if "ClusterID" not in arr.dtype.names:
        return np.ones(len(arr), dtype=bool)
    groups: dict[int, list[int]] = defaultdict(list)
    for idx, cid in enumerate(arr["ClusterID"]):
        groups[int(cid)].append(idx)

    keep = np.ones(len(arr), dtype=bool)
    dropped = 0
    for cid, idxs in groups.items():
        if cid <= 0 or len(idxs) < 20:
            continue
        pts = np.column_stack([arr["X"][idxs], arr["Y"][idxs], arr["Z"][idxs]]).astype(float)
        centered = pts - pts.mean(axis=0)
        eigvals = np.sort(np.linalg.eigvalsh(np.cov(centered.T)))[::-1]
        l0 = float(eigvals[0]) or 1e-9
        linearity = (l0 - float(eigvals[1])) / l0
        if linearity >= linearity_threshold:
            for i in idxs:
                keep[i] = False
            dropped += 1
    if dropped:
        job.append_log(f"{dropped} clustere liniare excluse (probabil linii electrice).")
    return keep


def _write_candidate(pdal, src, hag_min, out_path, job: Job) -> None:
    spec = {"pipeline": [
        str(src),
        {"type": "filters.range", "limits": f"HeightAboveGround[{hag_min}:1000],Classification![2:2]"},
        {"type": "writers.las", "filename": str(out_path), "compression": "laszip"},
    ]}
    pdal.Pipeline(json.dumps(spec)).execute()
    job.append_log(f"Nor candidat scris: {out_path.name}")


def _vectorize_footprints(xs, ys, zs, resolution, min_area, job: Job) -> list[dict]:
    """Grilă de ocupare → poligoane footprint (rasterio.features.shapes)."""
    try:
        import rasterio.features
        from affine import Affine
        from shapely.geometry import shape
        from shapely.ops import transform as shp_transform  # noqa: F401 (păstrat pentru extensii)
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError(
            "rasterio/shapely necesare pentru poligonizarea footprints (vezi requirements.txt)."
        ) from exc

    minx, miny = xs.min(), ys.min()
    maxx, maxy = xs.max(), ys.max()
    ncols = max(1, int(np.ceil((maxx - minx) / resolution)))
    nrows = max(1, int(np.ceil((maxy - miny) / resolution)))

    col = np.clip(((xs - minx) / resolution).astype(int), 0, ncols - 1)
    # rândurile cresc în jos în convenția raster; inversăm Y.
    row = np.clip(((maxy - ys) / resolution).astype(int), 0, nrows - 1)

    mask = np.zeros((nrows, ncols), dtype=np.uint8)
    height_sum = np.zeros((nrows, ncols), dtype=np.float64)
    height_cnt = np.zeros((nrows, ncols), dtype=np.int64)
    for r, c, z in zip(row, col, zs):
        mask[r, c] = 1
        height_sum[r, c] += z
        height_cnt[r, c] += 1

    transform = Affine.translation(minx, maxy) * Affine.scale(resolution, -resolution)
    cell_area = resolution * resolution

    polygons: list[dict] = []
    for geom, value in rasterio.features.shapes(mask, mask=mask.astype(bool), transform=transform):
        if value != 1:
            continue
        poly = shape(geom)
        if poly.area < min_area:
            continue
        # Înălțime medie din celulele acoperite de poligon (aproximare pe bbox-grid).
        mean_h = _mean_height_in_bounds(poly, transform, height_sum, height_cnt, minx, maxy, resolution)
        polygons.append({
            "geometry": json.loads(json.dumps(geom)),
            "area": round(float(poly.area), 2),
            "mean_height": round(mean_h, 2) if mean_h is not None else None,
        })
    return polygons


def _mean_height_in_bounds(poly, transform, height_sum, height_cnt, minx, maxy, resolution):
    bx0, by0, bx1, by1 = poly.bounds
    c0 = max(0, int((bx0 - minx) / resolution))
    c1 = min(height_sum.shape[1], int(np.ceil((bx1 - minx) / resolution)))
    r0 = max(0, int((maxy - by1) / resolution))
    r1 = min(height_sum.shape[0], int(np.ceil((maxy - by0) / resolution)))
    sub_sum = height_sum[r0:r1, c0:c1]
    sub_cnt = height_cnt[r0:r1, c0:c1]
    total_cnt = sub_cnt.sum()
    if total_cnt == 0:
        return None
    return float(sub_sum.sum() / total_cnt)


def _write_geojson(file_id: str, polygons: list[dict]) -> dict:
    crs_name = settings.default_target_srs
    features = [{
        "type": "Feature",
        "geometry": p["geometry"],
        "properties": {"kind": "building", "area": p["area"], "mean_height": p["mean_height"]},
    } for p in polygons]
    fc = {
        "type": "FeatureCollection",
        "crs": {"type": "name", "properties": {"name": f"urn:ogc:def:crs:{crs_name.replace(':', '::')}"}},
        "features": features,
    }
    out = out_dir(file_id) / "buildings.geojson"
    out.write_text(json.dumps(fc, ensure_ascii=False, indent=2))
    return {"output": str(out), "kind": "buildings", "n_footprints": len(polygons)}
