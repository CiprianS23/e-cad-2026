"""Conversie octree Potree (CLAUDE.md §8).

Un folder per scan în data/potree/<file_id>. Octree-ul păstrează Classification →
colorare în viewer pe schema de clasificare. Encoding BROTLI.
"""
from __future__ import annotations

import shutil

from .. import tools
from ..jobs import Job
from ..workspace import latest_artifact, potree_dir, resolve_input


def run(job: Job, params: dict) -> dict:
    file_id = job.file_id
    if not file_id:
        raise ValueError("potree: lipsește file_id")

    src = resolve_input(file_id, "potree") or latest_artifact(file_id)
    if src is None or not src.exists():
        raise FileNotFoundError(f"potree: niciun artefact de convertit pentru {file_id}")

    out = potree_dir(file_id)
    # PotreeConverter cere ca folderul țintă să fie gol / nou.
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True, exist_ok=True)

    job.append_log(f"Conversie Potree din {src.name}")
    job.set_progress(10)
    tools.potree_convert(src, out, job=job)
    job.set_progress(95)

    return {"scan_id": file_id, "potree_url": f"/potree-data/{file_id}",
            "source": str(src)}
