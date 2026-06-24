"""Reproiectare → EPSG:3844 (CLAUDE.md §6.2).

Dacă SRS-ul de intrare lipsește din header, se transmite `in_srs` (sursa) din
params. L2 livrează de regulă WGS84/UTM sau elipsoidal — se confirmă cu
utilizatorul înainte (altfel datele „zboară" în spațiu — CLAUDE.md §12).
"""
from __future__ import annotations

from ..jobs import Job
from ..settings import settings
from ..workspace import resolve_input, step_output
from . import run_pdal


def run(job: Job, params: dict) -> dict:
    file_id = job.file_id
    if not file_id:
        raise ValueError("reproject: lipsește file_id")

    src = resolve_input(file_id, "reproject")
    if src is None or not src.exists():
        raise FileNotFoundError(f"reproject: intrare inexistentă pentru {file_id}")

    out = step_output(file_id, "reproject")
    out_srs = params.get("out_srs") or settings.default_target_srs
    in_srs = params.get("in_srs")  # opțional; necesar dacă headerul nu are SRS

    reproj: dict = {"type": "filters.reprojection", "out_srs": out_srs}
    if in_srs:
        reproj["in_srs"] = in_srs
        job.append_log(f"in_srs forțat: {in_srs}")

    job.set_progress(10)
    count, _ = run_pdal([
        str(src),
        reproj,
        {"type": "writers.las", "filename": str(out), "compression": "laszip"},
    ], job=job)

    job.set_progress(95)
    return {"output": str(out), "point_count": count,
            "out_srs": out_srs, "in_srs": in_srs}
