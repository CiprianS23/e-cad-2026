"""Rezolvarea căilor pe scan (file_id) și înlănțuirea pașilor de pipeline.

Fiecare fișier încărcat primește un `file_id` (uuid). Fișierele intermediare
trăiesc în data/work/<file_id>/<nume canonic>. Output-urile de features în
data/out/<file_id>/. Octree-ul Potree în data/potree/<file_id>/.
"""
from __future__ import annotations

import re
from pathlib import Path

from .settings import settings

# Numele canonice ale output-urilor pe pași (CLAUDE.md §6).
STEP_SEQUENCE = ["normalize", "denoise", "reproject", "classify"]
STEP_OUTPUT = {
    "normalize": "normalized.laz",
    "denoise": "clean.laz",
    "reproject": "clean_3844.laz",
    "classify": "classified.laz",
}

_SAFE_NAME = re.compile(r"[^A-Za-z0-9._-]+")


def safe_filename(name: str) -> str:
    """Sanitizează un nume de fișier primit de la client."""
    name = Path(name).name  # taie eventuale componente de cale
    return _SAFE_NAME.sub("_", name).strip("._") or "fisier"


def work_dir(file_id: str) -> Path:
    d = settings.work_dir / file_id
    d.mkdir(parents=True, exist_ok=True)
    return d


def out_dir(file_id: str) -> Path:
    d = settings.out_dir / file_id
    d.mkdir(parents=True, exist_ok=True)
    return d


def potree_dir(file_id: str) -> Path:
    return settings.potree_dir / file_id


def work_path(file_id: str, name: str) -> Path:
    return work_dir(file_id) / name


def step_output(file_id: str, step: str) -> Path:
    """Calea de output canonică pentru un pas de pipeline."""
    return work_path(file_id, STEP_OUTPUT[step])


def source_upload(file_id: str) -> Path | None:
    """Găsește fișierul sursă încărcat pentru un file_id.

    Fișierele se salvează ca data/uploads/<file_id>__<nume original>.
    """
    matches = sorted(settings.uploads_dir.glob(f"{file_id}__*"))
    return matches[0] if matches else None


def latest_artifact(file_id: str) -> Path | None:
    """Cel mai procesat artefact existent pentru un scan (clasificat > ... > sursă)."""
    for step in reversed(STEP_SEQUENCE):
        p = step_output(file_id, step)
        if p.exists():
            return p
    return source_upload(file_id)


def resolve_input(file_id: str, step: str) -> Path | None:
    """Calea de intrare pentru un pas, parcurgând predecesorii existenți.

    Pentru pașii de pipeline (normalize..classify) caută output-ul celui mai
    apropiat predecesor existent, cu fallback pe fișierul sursă. Pentru pașii
    de features și potree folosește cel mai procesat artefact disponibil.
    """
    if step in STEP_SEQUENCE:
        idx = STEP_SEQUENCE.index(step)
        for prev in reversed(STEP_SEQUENCE[:idx]):
            p = step_output(file_id, prev)
            if p.exists():
                return p
        return source_upload(file_id)

    # features_* și potree: pleacă de la cel mai procesat artefact.
    return latest_artifact(file_id)
