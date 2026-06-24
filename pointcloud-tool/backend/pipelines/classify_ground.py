"""Clasificare sol (SMRF) + HeightAboveGround (CLAUDE.md §6.3).

SMRF → Classification 2 (sol) / 1 (neclasificat). filters.hag_nn adaugă
dimensiunea HeightAboveGround (HAG), folosită la toate features-urile.
SMRF (NU lasground, care e licențiat — CLAUDE.md §2).
"""
from __future__ import annotations

from ..jobs import Job
from ..workspace import resolve_input, step_output
from . import run_pdal


def run(job: Job, params: dict) -> dict:
    file_id = job.file_id
    if not file_id:
        raise ValueError("classify: lipsește file_id")

    src = resolve_input(file_id, "classify")
    if src is None or not src.exists():
        raise FileNotFoundError(f"classify: intrare inexistentă pentru {file_id}")

    out = step_output(file_id, "classify")
    scalar = float(params.get("scalar", 1.2))
    slope = float(params.get("slope", 0.2))
    threshold = float(params.get("threshold", 0.45))
    window = float(params.get("window", 16.0))

    job.set_progress(10)
    count, _ = run_pdal([
        str(src),
        {"type": "filters.smrf", "scalar": scalar, "slope": slope,
         "threshold": threshold, "window": window},
        {"type": "filters.hag_nn"},
        # Scriem HAG ca dimensiune extra ca să fie disponibilă în pașii de features.
        {"type": "writers.las", "filename": str(out), "compression": "laszip",
         "extra_dims": "HeightAboveGround=float32"},
    ], job=job)

    job.set_progress(95)
    return {"output": str(out), "point_count": count,
            "params": {"scalar": scalar, "slope": slope,
                       "threshold": threshold, "window": window}}
