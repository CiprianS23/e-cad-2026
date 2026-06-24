"""Linii electrice + stâlpi (CLAUDE.md §7.4) — tipic corridor scan L2.

1. Candidați: HeightAboveGround ~5–40 m, Classification ≠ 2 (sol).
2. filters.cluster (euclidian) pe candidați.
3. Per cluster → PCA:
     - 1 valoare proprie dominantă, axă cvasi-orizontală ⇒ linie electrică.
     - cluster vertical compact, footprint mic, înălțime mare ⇒ stâlp.
4. Linii → GeoJSON LineString (extreme pe axa principală).
   Stâlpi → GeoJSON Point (centroid).

Coordonatele rămân în SRS-ul norului (EPSG:3844), pentru overlay direct peste
octree-ul Potree (același sistem de coordonate).
"""
from __future__ import annotations

import json
from collections import defaultdict

import numpy as np

from ...jobs import Job
from ...settings import settings
from ...workspace import latest_artifact, out_dir, resolve_input


def run(job: Job, params: dict) -> dict:
    file_id = job.file_id
    if not file_id:
        raise ValueError("feature_powerlines: lipsește file_id")

    src = resolve_input(file_id, "feature_powerlines") or latest_artifact(file_id)
    if src is None or not src.exists():
        raise FileNotFoundError(f"feature_powerlines: intrare inexistentă pentru {file_id}")

    hag_min = float(params.get("hag_min", 5.0))
    hag_max = float(params.get("hag_max", 40.0))
    min_points = int(params.get("min_points", 10))
    tolerance = float(params.get("tolerance", 1.0))
    linearity_threshold = float(params.get("linearity_threshold", 0.9))

    try:
        import pdal
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError("Binding-ul `pdal` nu e instalat.") from exc

    job.set_progress(10)
    stages = [
        str(src),
        {"type": "filters.range",
         "limits": f"HeightAboveGround[{hag_min}:{hag_max}],Classification![2:2]"},
        {"type": "filters.cluster", "min_points": min_points, "tolerance": tolerance},
    ]
    job.append_log("PDAL cluster pe candidați linii/stâlpi:")
    job.append_log(json.dumps(stages, ensure_ascii=False, indent=2))
    pipeline = pdal.Pipeline(json.dumps({"pipeline": stages}))
    pipeline.execute()
    if not pipeline.arrays:
        job.append_log("Niciun punct candidat (interval HAG gol).")
        return _write_geojson(file_id, [], [])

    arr = pipeline.arrays[0]
    job.set_progress(50)

    # Gruparea pe ClusterID generat de filters.cluster.
    cluster_field = "ClusterID" if "ClusterID" in arr.dtype.names else None
    if cluster_field is None:
        raise RuntimeError("filters.cluster nu a produs dimensiunea ClusterID.")

    groups: dict[int, list[int]] = defaultdict(list)
    for idx, cid in enumerate(arr[cluster_field]):
        if cid > 0:  # 0 = nealocat
            groups[int(cid)].append(idx)

    lines: list[dict] = []
    poles: list[dict] = []
    for cid, idxs in groups.items():
        if len(idxs) < min_points:
            continue
        pts = np.column_stack([arr["X"][idxs], arr["Y"][idxs], arr["Z"][idxs]]).astype(float)
        kind, geom = _classify_cluster(pts, linearity_threshold)
        if kind == "line":
            lines.append({"cluster_id": cid, "n_points": len(idxs), "endpoints": geom})
        elif kind == "pole":
            poles.append({"cluster_id": cid, "n_points": len(idxs), "centroid": geom})

    job.append_log(f"{len(lines)} linii, {len(poles)} stâlpi detectați.")
    job.set_progress(90)
    return _write_geojson(file_id, lines, poles)


def _classify_cluster(pts: np.ndarray, linearity_threshold: float):
    """Întoarce ('line', [p0, p1]) sau ('pole', centroid) sau ('', None)."""
    centroid = pts.mean(axis=0)
    centered = pts - centroid
    # PCA pe 3D.
    cov = np.cov(centered.T)
    eigvals, eigvecs = np.linalg.eigh(cov)
    order = np.argsort(eigvals)[::-1]
    eigvals = eigvals[order]
    eigvecs = eigvecs[:, order]
    l0 = float(eigvals[0]) or 1e-9
    linearity = (l0 - float(eigvals[1])) / l0
    principal = eigvecs[:, 0]

    # Verticalitatea axei principale (|cos| cu Z).
    vert = abs(principal[2]) / (np.linalg.norm(principal) or 1e-9)
    height = float(pts[:, 2].max() - pts[:, 2].min())
    footprint = float(np.linalg.norm(pts[:, :2].max(axis=0) - pts[:, :2].min(axis=0)))

    if linearity >= linearity_threshold and vert < 0.5:
        # Alungit și cvasi-orizontal → linie electrică. Extreme pe axa principală.
        t = centered @ principal
        p0 = (centroid + principal * t.min()).tolist()
        p1 = (centroid + principal * t.max()).tolist()
        return "line", [p0, p1]

    if height > 3.0 and footprint < max(2.0 * 1.0, height * 0.5):
        # Vertical, compact, înalt → stâlp.
        return "pole", centroid.tolist()

    return "", None


def _write_geojson(file_id: str, lines: list[dict], poles: list[dict]) -> dict:
    crs_name = settings.default_target_srs
    features = []
    for ln in lines:
        (x0, y0, z0), (x1, y1, z1) = ln["endpoints"]
        features.append({
            "type": "Feature",
            "geometry": {"type": "LineString", "coordinates": [[x0, y0, z0], [x1, y1, z1]]},
            "properties": {"kind": "powerline", "cluster_id": ln["cluster_id"],
                           "n_points": ln["n_points"]},
        })
    for pole in poles:
        x, y, z = pole["centroid"]
        features.append({
            "type": "Feature",
            "geometry": {"type": "Point", "coordinates": [x, y, z]},
            "properties": {"kind": "pole", "cluster_id": pole["cluster_id"],
                           "n_points": pole["n_points"]},
        })

    fc = {
        "type": "FeatureCollection",
        "crs": {"type": "name", "properties": {"name": f"urn:ogc:def:crs:{crs_name.replace(':', '::')}"}},
        "features": features,
    }
    out = out_dir(file_id) / "powerlines.geojson"
    out.write_text(json.dumps(fc, ensure_ascii=False, indent=2))
    return {"output": str(out), "kind": "powerlines",
            "n_lines": len(lines), "n_poles": len(poles)}
