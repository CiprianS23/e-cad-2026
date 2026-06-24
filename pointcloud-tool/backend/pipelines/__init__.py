"""Pipeline-uri PDAL + extragere features.

Helper comun `run_pdal` care execută o specificație PDAL prin binding-ul Python
și raportează metadatele în log-ul jobului. Importul `pdal` e leneș, ca serverul
să pornească și fără binding instalat (UI-ul rămâne funcțional).
"""
from __future__ import annotations

import json
from typing import Any, Optional

from ..jobs import Job


def run_pdal(stages: list[Any], job: Optional[Job] = None) -> tuple[int, dict]:
    """Execută o specificație PDAL (lista de stage-uri) și întoarce (n_puncte, metadata)."""
    try:
        import pdal  # import leneș: lipsa lui nu trebuie să pice pornirea serverului
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError(
            "Binding-ul Python `pdal` nu e instalat. Vezi requirements.txt "
            "(recomandat conda/mamba)."
        ) from exc

    spec = json.dumps({"pipeline": stages})
    if job:
        job.append_log("PDAL pipeline:")
        job.append_log(json.dumps(stages, ensure_ascii=False, indent=2))
    pipeline = pdal.Pipeline(spec)
    count = pipeline.execute()
    if job:
        job.append_log(f"PDAL: {count} puncte procesate")
    try:
        meta = pipeline.metadata if isinstance(pipeline.metadata, dict) else json.loads(pipeline.metadata)
    except (ValueError, TypeError):
        meta = {}
    return count, meta
