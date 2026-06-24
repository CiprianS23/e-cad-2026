"""Configurare globală: căi binare, EPSG implicit, directoare de lucru.

Toate căile sunt rezolvate față de rădăcina proiectului (pointcloud-tool/).
Binarele externe se caută în ordinea:
  1. variabilă de mediu dedicată (ex. POTREECONVERTER_BIN)
  2. folderul bin/ din proiect
  3. PATH-ul sistemului (shutil.which)
"""
from __future__ import annotations

import os
import shutil
from pathlib import Path

# Rădăcina proiectului = pointcloud-tool/ (părintele lui backend/).
ROOT_DIR = Path(__file__).resolve().parent.parent
BIN_DIR = ROOT_DIR / "bin"

DATA_DIR = ROOT_DIR / "data"
UPLOADS_DIR = DATA_DIR / "uploads"
WORK_DIR = DATA_DIR / "work"
OUT_DIR = DATA_DIR / "out"
POTREE_DIR = DATA_DIR / "potree"

FRONTEND_DIR = ROOT_DIR / "frontend"
# Librăria Potree (build static oficial); poate lipsi la prima rulare.
POTREE_LIB_DIR = ROOT_DIR / "potree"

# Sistem de coordonate țintă fixat prin decizie (CLAUDE.md §2).
DEFAULT_TARGET_SRS = "EPSG:3844"

# Extensii acceptate la upload.
ALLOWED_EXTENSIONS = {".las", ".laz", ".e57"}


def _resolve_binary(env_var: str, *names: str) -> str:
    """Rezolvă un binar extern după env var → bin/ → PATH.

    Întoarce întotdeauna un string (numele binarului ca fallback), ca apelul
    să eșueze clar la rulare dacă unealta lipsește, fără să blocheze pornirea
    serverului.
    """
    override = os.environ.get(env_var)
    if override:
        return override
    for name in names:
        candidate = BIN_DIR / name
        if candidate.exists():
            return str(candidate)
        # și varianta .exe pe Windows
        candidate_exe = BIN_DIR / f"{name}.exe"
        if candidate_exe.exists():
            return str(candidate_exe)
    for name in names:
        found = shutil.which(name)
        if found:
            return found
    # Fallback: primul nume, lăsăm subprocess să raporteze lipsa.
    return names[0]


class Settings:
    """Container simplu pentru configurare (instanțiat o singură dată)."""

    root_dir = ROOT_DIR
    bin_dir = BIN_DIR
    data_dir = DATA_DIR
    uploads_dir = UPLOADS_DIR
    work_dir = WORK_DIR
    out_dir = OUT_DIR
    potree_dir = POTREE_DIR
    frontend_dir = FRONTEND_DIR
    potree_lib_dir = POTREE_LIB_DIR

    default_target_srs = DEFAULT_TARGET_SRS
    allowed_extensions = ALLOWED_EXTENSIONS

    @property
    def e57_to_las_bin(self) -> str:
        return _resolve_binary("E57_TO_LAS_BIN", "e57-to-las")

    @property
    def e572las_bin(self) -> str:
        return _resolve_binary("E572LAS_BIN", "e572las")

    @property
    def lasinfo_bin(self) -> str:
        return _resolve_binary("LASINFO_BIN", "lasinfo")

    @property
    def potreeconverter_bin(self) -> str:
        return _resolve_binary("POTREECONVERTER_BIN", "PotreeConverter")

    @property
    def cloudcompare_bin(self) -> str:
        return _resolve_binary("CLOUDCOMPARE_BIN", "CloudCompare")

    def ensure_dirs(self) -> None:
        """Creează directoarele de lucru dacă lipsesc."""
        for d in (self.uploads_dir, self.work_dir, self.out_dir, self.potree_dir):
            d.mkdir(parents=True, exist_ok=True)


settings = Settings()
