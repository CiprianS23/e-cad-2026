# Unealta de desenare a unei parcele (poligon) cu snapping, in stil AutoCAD.
# Click stanga = adauga vertex, click dreapta / dublu-click = inchide poligonul.
# Snapping-ul se bazeaza pe configurarea standard QGIS (QgsSnappingUtils), deci
# se prinde de vertecsii straturilor existente (limite tarla, parcele vecine).

from qgis.PyQt.QtCore import Qt
from qgis.PyQt.QtGui import QColor
from qgis.core import QgsPointXY, QgsGeometry, QgsWkbTypes
from qgis.gui import QgsMapToolEmitPoint, QgsRubberBand


class DrawParcelaTool(QgsMapToolEmitPoint):
    """Map tool pentru trasarea conturului unei parcele."""

    def __init__(self, canvas, iface):
        super().__init__(canvas)
        self.canvas = canvas
        self.iface = iface

        # Banda elastica (preview-ul poligonului in timpul desenarii).
        self.rubber_band = QgsRubberBand(canvas, QgsWkbTypes.PolygonGeometry)
        self.rubber_band.setColor(QColor(74, 144, 217, 60))
        self.rubber_band.setStrokeColor(QColor(74, 144, 217))
        self.rubber_band.setWidth(2)

        self.vertices = []

    # ------------------------------------------------------------------
    def _snap(self, event):
        """Returneaza punctul, prins de snapping daca exista o tinta apropiata."""
        match = self.canvas.snappingUtils().snapToMap(event.pos())
        if match.isValid():
            return QgsPointXY(match.point())
        return self.toMapCoordinates(event.pos())

    def canvasMoveEvent(self, event):
        if not self.vertices:
            return
        point = self._snap(event)
        temp = self.vertices + [point]
        self.rubber_band.setToGeometry(
            QgsGeometry.fromPolygonXY([temp]), None
        )
        self._show_running_info(temp)

    def canvasPressEvent(self, event):
        point = self._snap(event)
        if event.button() == Qt.LeftButton:
            self.vertices.append(point)
            self.rubber_band.setToGeometry(
                QgsGeometry.fromPolygonXY([self.vertices]), None
            )
        elif event.button() == Qt.RightButton:
            self._finish()

    def _finish(self):
        if len(self.vertices) < 3:
            self.iface.messageBar().pushWarning(
                "Cadastru", "Parcela are nevoie de minim 3 puncte."
            )
            self._reset()
            return

        geom = QgsGeometry.fromPolygonXY([self.vertices])
        area = geom.area()
        perimeter = geom.length()
        self.iface.messageBar().pushInfo(
            "Cadastru",
            f"Parcela trasata: suprafata {area:.2f} mp, perimetru {perimeter:.2f} m. "
            "(TODO: salvare in stratul de parcele / e-CAD)",
        )
        # TODO: adauga geometria in stratul editabil de parcele si deschide
        #       formularul de atribute (nr cadastral, tarla, proprietar).
        self._reset()

    def _show_running_info(self, points):
        """Afiseaza in bara de stare lungimea ultimei laturi (ca in AutoCAD)."""
        if len(points) < 2:
            return
        last = QgsGeometry.fromPolylineXY(points[-2:]).length()
        self.iface.statusBarIface().showMessage(f"Latura: {last:.2f} m")

    def _reset(self):
        self.vertices = []
        self.rubber_band.reset(QgsWkbTypes.PolygonGeometry)

    def deactivate(self):
        self._reset()
        super().deactivate()
