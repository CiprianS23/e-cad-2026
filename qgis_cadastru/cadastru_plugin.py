# Clasa principala a plugin-ului de cadastru.
# Orchestreaza: aplicarea temei AutoCAD-like, curatarea profilului (ascunderea
# meniurilor GIS irelevante), construirea toolbar-ului de cadastru, dock-ul cu
# linia de comanda si pun~tile de integrare cu e-CAD.

import os

from qgis.PyQt.QtCore import Qt
from qgis.PyQt.QtGui import QIcon
from qgis.PyQt.QtWidgets import QAction, QToolBar

from .ui.theme import apply_autocad_theme, remove_autocad_theme
from .ui.command_line import CommandLineDock
from .profile.profile_cleanup import ProfileCleaner
from .tools.draw_parcela import DrawParcelaTool
from .tools.measure import MeasureDistanceTool
from .ecad.connection import EcadConnection
from .ecad import cgxml

PLUGIN_DIR = os.path.dirname(__file__)


def _icon(name):
    """Returneaza un QIcon din folderul resources (sau gol daca lipseste)."""
    path = os.path.join(PLUGIN_DIR, "resources", name)
    return QIcon(path) if os.path.exists(path) else QIcon()


class CadastruPlugin:
    """Plugin care da QGIS-ului un comportament de aplicatie de cadastru."""

    def __init__(self, iface):
        self.iface = iface
        self.canvas = iface.mapCanvas()

        # Componente create la initGui().
        self.toolbar = None
        self.actions = []
        self.command_dock = None
        self.profile_cleaner = ProfileCleaner(iface)
        self.ecad = EcadConnection()

        # Unelte de harta (map tools) tinute ca atribute ca sa nu fie colectate.
        self.tool_parcela = None
        self.tool_measure = None

    # ------------------------------------------------------------------
    # Ciclul de viata cerut de QGIS
    # ------------------------------------------------------------------
    def initGui(self):
        """Apelat de QGIS cand plugin-ul este activat."""
        # 1. Aspect AutoCAD-like (tema intunecata, cursor, fundal canvas).
        apply_autocad_theme(self.iface)

        # 2. Ascunde meniurile/toolbar-urile generale care nu sunt utile in cadastru.
        self.profile_cleaner.apply()

        # 3. Toolbar propriu de cadastru.
        self.toolbar = self.iface.addToolBar("Cadastru e-CAD")
        self.toolbar.setObjectName("CadastruToolbar")
        self._build_tools()

        # 4. Linia de comanda tip AutoCAD (dock jos), cu interpretare in limbaj
        #    natural prin Claude. Comenzile sunt rutate prin acelasi registru.
        self.command_dock = CommandLineDock(self.iface, self._commands())
        self.iface.addDockWidget(Qt.BottomDockWidgetArea, self.command_dock)

    def unload(self):
        """Apelat de QGIS cand plugin-ul este dezactivat. Curatam tot ce am adaugat."""
        if self.command_dock is not None:
            self.iface.removeDockWidget(self.command_dock)
            self.command_dock.deleteLater()
            self.command_dock = None

        for action in self.actions:
            self.toolbar.removeAction(action)
        self.actions = []

        if self.toolbar is not None:
            del self.toolbar
            self.toolbar = None

        # Reseteaza unealta activa pe cea implicita (pan).
        self.canvas.unsetMapTool(self.canvas.mapTool())

        # Reda profilul QGIS standard si tema implicita.
        self.profile_cleaner.restore()
        remove_autocad_theme(self.iface)

    # ------------------------------------------------------------------
    # Constructie unelte
    # ------------------------------------------------------------------
    def _add_action(self, icon_name, text, callback, checkable=False, tooltip=None):
        action = QAction(_icon(icon_name), text, self.iface.mainWindow())
        action.triggered.connect(callback)
        action.setCheckable(checkable)
        action.setToolTip(tooltip or text)
        self.toolbar.addAction(action)
        self.actions.append(action)
        return action

    def _build_tools(self):
        self.tool_parcela = DrawParcelaTool(self.canvas, self.iface)
        self.tool_measure = MeasureDistanceTool(self.canvas, self.iface)

        self._add_action("parcela.png", "Parcela noua", self.activate_draw_parcela,
                         checkable=True, tooltip="Deseneaza o parcela (PARCELA / PA)")
        self._add_action("measure.png", "Masoara distanta", self.activate_measure,
                         checkable=True, tooltip="Masoara distanta (DI)")
        self.toolbar.addSeparator()
        self._add_action("import.png", "Import din e-CAD", self.import_from_ecad,
                         tooltip="Importa parcele/imobile din baza e-CAD")
        self._add_action("cgxml.png", "Export cgxml", self.export_cgxml,
                         tooltip="Genereaza fisier cgxml pentru ANCPI")

    # ------------------------------------------------------------------
    # Actiuni (apelate si din toolbar, si din linia de comanda)
    # ------------------------------------------------------------------
    def activate_draw_parcela(self):
        self.canvas.setMapTool(self.tool_parcela)

    def activate_measure(self):
        self.canvas.setMapTool(self.tool_measure)

    def zoom_full(self):
        self.iface.zoomFull()

    def import_from_ecad(self):
        """Aduce stratul de parcele/imobile din e-CAD ca layer PostGIS."""
        self.ecad.load_parcele_layer(self.iface)

    def export_cgxml(self):
        """Exporta selectia curenta in format cgxml (stub - vezi ecad/cgxml.py)."""
        cgxml.export_current_selection(self.iface)

    # ------------------------------------------------------------------
    # Registrul de comenzi pentru linia de comanda
    # ------------------------------------------------------------------
    def _commands(self):
        """Descrie comenzile aplicatiei.

        Fiecare comanda are:
          - name: identificator canonic (si numele tool-ului trimis lui Claude)
          - aliases: scurtaturi tip AutoCAD, pentru executie rapida fara API
          - description: text in romana, folosit ca descriere a tool-ului pentru
            interpretarea in limbaj natural
          - callback: actiunea efectiva

        Aceeasi lista alimenteaza atat executia directa (alias exact) cat si
        interpretarea in limbaj natural prin Claude.
        """
        return [
            {
                "name": "parcela",
                "aliases": ["pa", "parcela"],
                "description": (
                    "Porneste desenarea unei parcele noi (poligon) pe harta, cu "
                    "snapping la straturile existente. Foloseste cand utilizatorul "
                    "vrea sa traseze/deseneze o parcela, un contur sau o limita."
                ),
                "callback": self.activate_draw_parcela,
            },
            {
                "name": "masoara",
                "aliases": ["di", "dist", "masoara"],
                "description": (
                    "Activeaza unealta de masurare a distantei intre doua puncte. "
                    "Foloseste cand utilizatorul vrea sa masoare o distanta sau o "
                    "lungime pe harta."
                ),
                "callback": self.activate_measure,
            },
            {
                "name": "extent",
                "aliases": ["ze", "extent"],
                "description": (
                    "Face zoom la extinderea completa a tuturor straturilor "
                    "(vezi toata harta). Foloseste pentru 'arata tot', 'zoom "
                    "general', 'incadreaza harta'."
                ),
                "callback": self.zoom_full,
            },
            {
                "name": "import",
                "aliases": ["imp", "import"],
                "description": (
                    "Importa imobilele/parcelele din baza de date e-CAD ca strat "
                    "pe harta. Foloseste pentru 'adu parcelele', 'incarca imobilele "
                    "din e-CAD', 'importa datele'."
                ),
                "callback": self.import_from_ecad,
            },
            {
                "name": "cgxml",
                "aliases": ["cgxml", "export"],
                "description": (
                    "Exporta selectia curenta in format cgxml (livrabilul ANCPI). "
                    "Foloseste pentru 'exporta cgxml', 'genereaza fisierul pentru "
                    "ANCPI', 'export cadastru'."
                ),
                "callback": self.export_cgxml,
            },
        ]
