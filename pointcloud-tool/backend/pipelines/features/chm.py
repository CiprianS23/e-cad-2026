"""CHM — Canopy Height Model / vegetație (CLAUDE.md §7.2).

HAG filtrat pe interval (implicit 2–60 m, separă vegetația de obiecte joase și
outlieri foarte înalți) → GeoTIFF pe dimensiunea HeightAboveGround, output max.
"""
from __future__ import annotations

from ...jobs import Job
from ...workspace import latest_artifact, out_dir, resolve_input
from .. import run_pdal


def run(job: Job, params: dict) -> dict:
    file_id = job.file_id
    if not file_id:
        raise ValueError("feature_chm: lipsește file_id")

    src = resolve_input(file_id, "feature_chm") or latest_artifact(file_id)
    if src is None or not src.exists():
        raise FileNotFoundError(f"feature_chm: intrare inexistentă pentru {file_id}")

    out = out_dir(file_id) / "chm.tif"
    resolution = float(params.get("resolution", 0.5))
    hmin = float(params.get("hag_min", 2.0))
    hmax = float(params.get("hag_max", 60.0))

    job.set_progress(10)
    run_pdal([
        str(src),
        {"type": "filters.range", "limits": f"HeightAboveGround[{hmin}:{hmax}]"},
        {"type": "writers.gdal", "filename": str(out), "dimension": "HeightAboveGround",
         "resolution": resolution, "output_type": "max", "gdaldriver": "GTiff"},
    ], job=job)

    job.set_progress(95)
    return {"output": str(out), "kind": "chm", "resolution": resolution,
            "hag_range": [hmin, hmax]}
