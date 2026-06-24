"""Normalizare intrare: E57 → LAZ, validare header (CLAUDE.md §5).

LAS/LAZ intră direct (copiate ca `normalized.laz` prin las2las/PDAL writer).
E57 se convertește cu e57-to-las (implicit) sau e572las (fallback).
După conversie se rulează lasinfo pentru validare bbox/SRS.
"""
from __future__ import annotations

import shutil
from pathlib import Path

from .. import tools
from ..jobs import Job
from ..workspace import resolve_input, step_output, work_dir
from . import run_pdal


def run(job: Job, params: dict) -> dict:
    file_id = job.file_id
    if not file_id:
        raise ValueError("normalize: lipsește file_id")

    src = resolve_input(file_id, "normalize")
    if src is None or not src.exists():
        raise FileNotFoundError(f"normalize: fișier sursă inexistent pentru {file_id}")

    out = step_output(file_id, "normalize")
    wdir = work_dir(file_id)
    ext = src.suffix.lower()
    job.set_progress(10)

    if ext == ".e57":
        use_fallback = bool(params.get("use_e572las"))
        if use_fallback:
            job.append_log("Conversie E57 cu e572las (fallback).")
            tools.e572las(src, out, job=job)
        else:
            job.append_log("Conversie E57 cu e57-to-las (implicit).")
            tools.e57_to_las(src, wdir, job=job)
            out = _pick_converted_las(wdir, out, job)
        job.set_progress(60)
    else:
        # LAS/LAZ: normalizăm la LAZ printr-o trecere PDAL (validează și headerul).
        job.append_log(f"Intrare {ext} → normalizare la LAZ.")
        run_pdal([str(src), {"type": "writers.las", "filename": str(out),
                             "compression": "laszip"}], job=job)
        job.set_progress(60)

    # Validare cu lasinfo (CLAUDE.md §5.3).
    info: dict = {}
    try:
        info = tools.lasinfo(out, job=job)
        if not info.get("has_srs"):
            job.append_log("ATENȚIE: SRS absent din header — se va cere la reproiectare.")
        bbox = info.get("bbox")
        if bbox:
            job.append_log(f"bbox: min={bbox['min']} max={bbox['max']}")
    except tools.ToolError as exc:
        job.append_log(f"lasinfo indisponibil ({exc}); sar validarea.")

    job.set_progress(95)
    return {"output": str(out), "info": info}


def _pick_converted_las(wdir: Path, preferred: Path, job: Job) -> Path:
    """Alege fișierul LAS/LAZ produs de e57-to-las (poate fi unul sau mai multe stații).

    Dacă există mai multe (mai multe stații), se ia primul și se semnalează că
    pipeline-ul de denoise poate face merge ulterior.
    """
    candidates = sorted(
        p for p in wdir.glob("*") if p.suffix.lower() in (".las", ".laz") and p != preferred
    )
    if not candidates:
        raise FileNotFoundError("e57-to-las nu a produs niciun fișier LAS/LAZ.")
    if len(candidates) > 1:
        job.append_log(f"{len(candidates)} stații convertite; se folosește prima ({candidates[0].name}).")
    chosen = candidates[0]
    if chosen != preferred:
        shutil.copy2(chosen, preferred)
    return preferred
