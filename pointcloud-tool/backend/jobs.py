"""Coadă de joburi în background + status/progres/log, cu persistență JSON.

Procesarea PDAL/CloudCompare/PotreeConverter e blocantă, deci joburile rulează
pe un thread separat. UI face polling pe GET /api/jobs/{id}. Joburile grele se
serializează (un singur worker) ca să nu se bată pe CPU/RAM și pe aceleași
fișiere intermediare.
"""
from __future__ import annotations

import json
import threading
import time
import traceback
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable, Optional

from .settings import settings


class JobStatus(str, Enum):
    QUEUED = "queued"
    RUNNING = "running"
    DONE = "done"
    ERROR = "error"


# Semnătura funcției de lucru: primește jobul (pentru log/progres) și params.
JobFn = Callable[["Job", dict], Optional[dict]]

# Limită log în memorie (linii) ca să nu crească nelimitat la dataset-uri mari.
MAX_LOG_LINES = 5000


@dataclass
class Job:
    id: str
    step: str
    file_id: Optional[str] = None
    params: dict = field(default_factory=dict)
    status: JobStatus = JobStatus.QUEUED
    progress: int = 0
    log: list[str] = field(default_factory=list)
    result: Optional[dict] = None
    error: Optional[str] = None
    created_at: float = field(default_factory=time.time)
    started_at: Optional[float] = None
    finished_at: Optional[float] = None

    # --- API folosit din funcțiile de lucru (thread-safe pentru CPython) ---
    def append_log(self, line: str) -> None:
        for piece in str(line).splitlines() or [""]:
            self.log.append(piece)
        if len(self.log) > MAX_LOG_LINES:
            del self.log[: len(self.log) - MAX_LOG_LINES]

    def set_progress(self, value: int) -> None:
        self.progress = max(0, min(100, int(value)))

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "step": self.step,
            "file_id": self.file_id,
            "status": self.status.value,
            "progress": self.progress,
            "log": self.log,
            "result": self.result,
            "error": self.error,
            "created_at": self.created_at,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
        }


class JobManager:
    def __init__(self) -> None:
        self._jobs: dict[str, Job] = {}
        self._lock = threading.Lock()
        # Un singur worker: joburile grele se execută serial.
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="job")
        self._persist_path = settings.data_dir / "jobs.json"

    def submit(self, step: str, fn: JobFn, file_id: Optional[str] = None,
               params: Optional[dict] = None) -> Job:
        job = Job(id=uuid.uuid4().hex, step=step, file_id=file_id,
                  params=params or {})
        with self._lock:
            self._jobs[job.id] = job
        self._persist()
        self._executor.submit(self._run, job, fn)
        return job

    def get(self, job_id: str) -> Optional[Job]:
        with self._lock:
            return self._jobs.get(job_id)

    def all(self) -> list[Job]:
        with self._lock:
            return sorted(self._jobs.values(), key=lambda j: j.created_at, reverse=True)

    def _run(self, job: Job, fn: JobFn) -> None:
        job.status = JobStatus.RUNNING
        job.started_at = time.time()
        job.append_log(f"[{job.step}] start")
        try:
            result = fn(job, job.params)
            job.result = result if isinstance(result, dict) else ({} if result is None else {"value": result})
            job.set_progress(100)
            job.status = JobStatus.DONE
            job.append_log(f"[{job.step}] gata")
        except Exception as exc:  # noqa: BLE001 - vrem să capturăm orice eroare în log
            job.status = JobStatus.ERROR
            job.error = str(exc)
            job.append_log("EROARE: " + str(exc))
            job.append_log(traceback.format_exc())
        finally:
            job.finished_at = time.time()
            self._persist()

    def _persist(self) -> None:
        """Salvează un snapshot al joburilor (best-effort, fără să arunce)."""
        try:
            settings.ensure_dirs()
            with self._lock:
                snapshot = [j.to_dict() for j in self._jobs.values()]
            tmp = self._persist_path.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2))
            tmp.replace(self._persist_path)
        except OSError:
            pass


# Instanță unică folosită de aplicație.
jobs = JobManager()
