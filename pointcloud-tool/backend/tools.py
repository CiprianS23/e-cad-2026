"""Wrappers subprocess pentru uneltele externe.

Toate apelurile streamează stdout/stderr în log-ul jobului pentru depanare
(CLAUDE.md §9). Funcțiile aruncă ToolError la cod de retur ≠ 0.
"""
from __future__ import annotations

import re
import subprocess
from pathlib import Path
from typing import Optional, Sequence

from .jobs import Job
from .settings import settings


class ToolError(RuntimeError):
    pass


def run_command(cmd: Sequence[str], job: Optional[Job] = None,
                cwd: Optional[Path] = None) -> str:
    """Rulează o comandă externă, streamând output-ul în log-ul jobului.

    Întoarce stdout-ul agregat. Aruncă ToolError dacă procesul eșuează.
    """
    printable = " ".join(str(c) for c in cmd)
    if job:
        job.append_log("$ " + printable)
    try:
        proc = subprocess.Popen(
            [str(c) for c in cmd],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            cwd=str(cwd) if cwd else None,
        )
    except FileNotFoundError as exc:
        raise ToolError(f"Binar negăsit pentru comanda: {cmd[0]} ({exc})") from exc

    lines: list[str] = []
    assert proc.stdout is not None
    for raw in proc.stdout:
        line = raw.rstrip("\n")
        lines.append(line)
        if job:
            job.append_log(line)
    proc.wait()
    if proc.returncode != 0:
        raise ToolError(f"Comanda a eșuat (cod {proc.returncode}): {printable}")
    return "\n".join(lines)


# --------------------------------------------------------------------------
# Conversie E57 (CLAUDE.md §5.1)
# --------------------------------------------------------------------------

def e57_to_las(src: Path, out_dir: Path, job: Optional[Job] = None) -> str:
    """Convertor implicit: e57-to-las (nivalis-studio), produce LAS 1.4 + stations.json."""
    cmd = [
        settings.e57_to_las_bin,
        "-p", str(src),
        "-o", str(out_dir),
        "--stations",
        "-L", "1.4",
        "-T", "0",
    ]
    return run_command(cmd, job=job)


def e572las(src: Path, out: Path, job: Optional[Job] = None) -> str:
    """Fallback E57: e572las (LAStools, gratuit). Alpha — output-ul se validează."""
    cmd = [settings.e572las_bin, "-v", "-i", str(src), "-o", str(out)]
    return run_command(cmd, job=job)


# --------------------------------------------------------------------------
# lasinfo — validare header (CLAUDE.md §5.3)
# --------------------------------------------------------------------------

def lasinfo(path: Path, job: Optional[Job] = None) -> dict:
    """Rulează lasinfo și extrage câteva metrici (puncte, bbox, SRS, RGB)."""
    out = run_command([settings.lasinfo_bin, "-i", str(path), "-nc", "-nv"], job=job)
    return _parse_lasinfo(out)


def _parse_lasinfo(text: str) -> dict:
    info: dict = {"has_srs": False, "has_rgb": False}
    m = re.search(r"number of point records:\s+(\d+)", text, re.I)
    if m:
        info["point_count"] = int(m.group(1))
    mn = re.search(r"min x y z:\s*([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)", text, re.I)
    mx = re.search(r"max x y z:\s*([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)", text, re.I)
    if mn and mx:
        info["bbox"] = {
            "min": [float(mn.group(1)), float(mn.group(2)), float(mn.group(3))],
            "max": [float(mx.group(1)), float(mx.group(2)), float(mx.group(3))],
        }
    if re.search(r"(epsg|wkt|projcs|geogcs|spatialreference)", text, re.I):
        info["has_srs"] = True
    if re.search(r"\b(red|green|blue)\b", text, re.I):
        info["has_rgb"] = True
    return info


# --------------------------------------------------------------------------
# CloudCompare — detecție plane RANSAC pentru clădiri (CLAUDE.md §7.3)
# --------------------------------------------------------------------------

def cloudcompare_ransac(src: Path, job: Optional[Job] = None) -> str:
    """Segmentare plane RANSAC pe norul candidat de clădiri.

    Parametrii RANSAC se calibrează per tip de structură (CLAUDE.md §12).
    """
    cmd = [
        settings.cloudcompare_bin,
        "-SILENT",
        "-O", str(src),
        "-RANSAC", "ENABLE_PRIMITIVE", "PLANE",
        "-SAVE_CLOUDS",
    ]
    return run_command(cmd, job=job, cwd=src.parent)


# --------------------------------------------------------------------------
# PotreeConverter (CLAUDE.md §8)
# --------------------------------------------------------------------------

def potree_convert(src: Path, out_dir: Path, job: Optional[Job] = None) -> str:
    cmd = [
        settings.potreeconverter_bin,
        str(src),
        "-o", str(out_dir),
        "--encoding", "BROTLI",
    ]
    return run_command(cmd, job=job)
