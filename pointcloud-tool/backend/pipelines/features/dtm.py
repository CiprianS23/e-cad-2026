"""DTM/DEM — model digital al terenului (CLAUDE.md §7.1).

Sol (Classification=2) → GeoTIFF prin writers.gdal cu interpolare IDW.
"""
from __future__ import annotations

from ...jobs import Job
from ...workspace import latest_artifact, out_dir, resolve_input
from .. import run_pdal


def run(job: Job, params: dict) -> dict:
    file_id = job.file_id
    if not file_id:
        raise ValueError("feature_dtm: lipsește file_id")

    src = resolve_input(file_id, "feature_dtm") or latest_artifact(file_id)
    if src is None or not src.exists():
        raise FileNotFoundError(f"feature_dtm: intrare inexistentă pentru {file_id}")

    out = out_dir(file_id) / "dtm.tif"
    resolution = float(params.get("resolution", 0.5))

    job.set_progress(10)
    run_pdal([
        str(src),
        {"type": "filters.range", "limits": "Classification[2:2]"},
        {"type": "writers.gdal", "filename": str(out),
         "resolution": resolution, "output_type": "idw", "gdaldriver": "GTiff"},
    ], job=job)

    job.set_progress(95)
    return {"output": str(out), "kind": "dtm", "resolution": resolution}
