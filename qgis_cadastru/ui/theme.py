# Tema vizuala in stil AutoCAD: fundal inchis pe canvas, paleta intunecata pe UI.
# Aplicam un stylesheet Qt (QSS) peste fereastra principala QGIS si setam
# culoarea de fundal a hartii. La descarcarea plugin-ului, revenim la implicit.

import os

from qgis.PyQt.QtGui import QColor

RESOURCES_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "resources")
QSS_PATH = os.path.join(RESOURCES_DIR, "theme.qss")

# Cheie de setari unde salvam stylesheet-ul anterior, ca sa-l putem reda.
_PREV_STYLESHEET = {"value": None}

# Culoarea de fundal a canvas-ului in stil AutoCAD model space (aproape negru).
AUTOCAD_CANVAS_BG = QColor(33, 33, 33)


def _load_qss():
    if os.path.exists(QSS_PATH):
        with open(QSS_PATH, "r", encoding="utf-8") as fh:
            return fh.read()
    return ""


def apply_autocad_theme(iface):
    """Aplica tema intunecata AutoCAD-like pe fereastra principala si pe harta."""
    main_window = iface.mainWindow()

    # Salveaza stylesheet-ul curent pentru a-l putea restaura.
    _PREV_STYLESHEET["value"] = main_window.styleSheet()
    main_window.setStyleSheet(_load_qss())

    # Fundal canvas intunecat (model space).
    canvas = iface.mapCanvas()
    canvas.setCanvasColor(AUTOCAD_CANVAS_BG)
    canvas.refresh()


def remove_autocad_theme(iface):
    """Revine la tema implicita QGIS."""
    main_window = iface.mainWindow()
    if _PREV_STYLESHEET["value"] is not None:
        main_window.setStyleSheet(_PREV_STYLESHEET["value"])
        _PREV_STYLESHEET["value"] = None

    canvas = iface.mapCanvas()
    canvas.setCanvasColor(QColor(255, 255, 255))
    canvas.refresh()
