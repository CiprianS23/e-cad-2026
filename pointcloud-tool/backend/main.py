"""FastAPI app: rute API + montări statice (CLAUDE.md §9).

Pornește chiar dacă PDAL/binarele externe lipsesc — UI-ul rămâne servit, iar
joburile raportează eroare clară la rulare. Frontend pe `/`, octree-uri pe
`/potree-data/<scan_id>`, librăria Potree pe `/potree`.
"""
from __future__ import annotations

from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException, UploadFile, File, Form
from fastapi.responses import JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
import uuid
import json

from .jobs import jobs
from .settings import settings
from .workspace import (
    out_dir,
    potree_dir,
    safe_filename,
    source_upload,
)

from .pipelines import normalize, denoise, reproject, classify_ground, to_potree
from .pipelines.features import dtm, chm, buildings, powerlines

# Maparea step → funcție de lucru (CLAUDE.md §9).
STEP_HANDLERS = {
    "normalize": normalize.run,
    "denoise": denoise.run,
    "reproject": reproject.run,
    "classify": classify_ground.run,
    "feature_dtm": dtm.run,
    "feature_chm": chm.run,
    "feature_buildings": buildings.run,
    "feature_powerlines": powerlines.run,
    "potree": to_potree.run,
}

app = FastAPI(title="Point Cloud Tool", version="0.1.0")


class RunRequest(BaseModel):
    file_id: str
    params: dict = {}


@app.on_event("startup")
def _startup() -> None:
    settings.ensure_dirs()


# --------------------------------------------------------------------------
# API
# --------------------------------------------------------------------------

@app.post("/api/upload")
async def upload(file: UploadFile = File(...)) -> dict:
    ext = Path(file.filename or "").suffix.lower()
    if ext not in settings.allowed_extensions:
        raise HTTPException(400, f"Extensie neacceptată: {ext}. "
                                 f"Acceptate: {sorted(settings.allowed_extensions)}")
    settings.ensure_dirs()
    file_id = uuid.uuid4().hex
    dest = settings.uploads_dir / f"{file_id}__{safe_filename(file.filename or 'fisier')}"
    size = 0
    with dest.open("wb") as fh:
        while chunk := await file.read(1024 * 1024):
            size += len(chunk)
            fh.write(chunk)
    return {"file_id": file_id, "filename": dest.name, "size": size, "ext": ext}


@app.post("/api/run/{step}")
def run_step(step: str, req: RunRequest) -> dict:
    if step not in STEP_HANDLERS:
        raise HTTPException(404, f"Pas necunoscut: {step}")
    if source_upload(req.file_id) is None:
        raise HTTPException(404, f"file_id necunoscut: {req.file_id}")
    job = jobs.submit(step, STEP_HANDLERS[step], file_id=req.file_id, params=req.params or {})
    return {"job_id": job.id, "step": step, "status": job.status.value}


@app.get("/api/jobs/{job_id}")
def get_job(job_id: str) -> dict:
    job = jobs.get(job_id)
    if job is None:
        raise HTTPException(404, "Job necunoscut")
    return job.to_dict()


@app.get("/api/jobs")
def list_jobs() -> dict:
    return {"jobs": [j.to_dict() for j in jobs.all()]}


@app.get("/api/features/{scan_id}")
def list_features(scan_id: str) -> dict:
    d = out_dir(scan_id)
    items = []
    for p in sorted(d.glob("*")):
        if p.suffix.lower() in (".geojson", ".json"):
            items.append({"name": p.name, "kind": "vector",
                          "url": f"/api/features/{scan_id}/{p.name}"})
        elif p.suffix.lower() in (".tif", ".tiff"):
            items.append({"name": p.name, "kind": "raster",
                          "url": f"/out-data/{scan_id}/{p.name}"})
    return {"scan_id": scan_id, "features": items}


@app.get("/api/features/{scan_id}/{name}")
def get_feature(scan_id: str, name: str):
    p = out_dir(scan_id) / safe_filename(name)
    if not p.exists():
        raise HTTPException(404, "Feature inexistent")
    if p.suffix.lower() in (".geojson", ".json"):
        return JSONResponse(json.loads(p.read_text()))
    raise HTTPException(400, "Folosește /out-data pentru raster.")


@app.get("/api/scans")
def list_scans() -> dict:
    scans = []
    for d in sorted(settings.potree_dir.glob("*")):
        if d.is_dir() and (d / "metadata.json").exists():
            scans.append({"scan_id": d.name, "potree_url": f"/potree-data/{d.name}"})
    return {"scans": scans}


# --------------------------------------------------------------------------
# Montări statice
# --------------------------------------------------------------------------

def _mount_static() -> None:
    settings.ensure_dirs()
    # Octree-urile Potree (un folder per scan).
    app.mount("/potree-data", StaticFiles(directory=str(settings.potree_dir)), name="potree-data")
    # Raster features descărcabile.
    app.mount("/out-data", StaticFiles(directory=str(settings.out_dir)), name="out-data")
    # Librăria Potree (build static), dacă e prezentă.
    if settings.potree_lib_dir.exists():
        app.mount("/potree", StaticFiles(directory=str(settings.potree_lib_dir), html=True), name="potree")
    # Frontend pe rădăcină (ultima montare = catch-all).
    if settings.frontend_dir.exists():
        app.mount("/", StaticFiles(directory=str(settings.frontend_dir), html=True), name="frontend")
    else:
        @app.get("/")
        def _root():  # pragma: no cover
            return RedirectResponse("/docs")


_mount_static()
