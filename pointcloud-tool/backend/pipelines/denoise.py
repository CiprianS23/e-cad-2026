"""Denoise + eliminarea zgomotului (CLAUDE.md §6.1).

filters.outlier marchează zgomotul ca Classification 7; filters.range îl elimină.
Parametrii mean_k / multiplier sunt editabili din UI.
"""
from __future__ import annotations

from ..jobs import Job
from ..workspace import resolve_input, step_output
from . import run_pdal


def run(job: Job, params: dict) -> dict:
    file_id = job.file_id
    if not file_id:
        raise ValueError("denoise: lipsește file_id")

    src = resolve_input(file_id, "denoise")
    if src is None or not src.exists():
        raise FileNotFoundError(f"denoise: intrare inexistentă pentru {file_id}")

    out = step_output(file_id, "denoise")
    mean_k = int(params.get("mean_k", 12))
    multiplier = float(params.get("multiplier", 2.2))

    job.set_progress(10)
    count, _ = run_pdal([
        str(src),
        {"type": "filters.outlier", "method": "statistical",
         "mean_k": mean_k, "multiplier": multiplier},
        {"type": "filters.range", "limits": "Classification![7:7]"},
        {"type": "writers.las", "filename": str(out), "compression": "laszip"},
    ], job=job)

    job.set_progress(95)
    return {"output": str(out), "point_count": count,
            "params": {"mean_k": mean_k, "multiplier": multiplier}}
