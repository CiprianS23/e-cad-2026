# Unealta simpla de masurare a distantei intre doua puncte (comanda "DI").
# Foloseste QgsDistanceArea pentru calcul corect (elipsoidal sau planar, dupa CRS).

from qgis.PyQt.QtCore import Qt
from qgis.PyQt.QtGui import QColor
from qgis.core import QgsDistanceArea, QgsProject, QgsPointXY, QgsGeometry, QgsWkbTypes
from qgis.gui import QgsMapToolEmitPoint, QgsRubberBand


class MeasureDistanceTool(QgsMapToolEmitPoint):
    """Masoara distanta intre doua click-uri pe harta."""

    def __init__(self, canvas, iface):
        super().__init__(canvas)
        self.canvas = canvas
        self.iface = iface
        self.start_point = None

        self.rubber_band = QgsRubberBand(canvas, QgsWkbTypes.LineGeometry)
        self.rubber_band.setColor(QColor(255, 170, 0))
        self.rubber_band.setWidth(2)

        # Calculator de distante configurat pe CRS-ul proiectului.
        self.measurer = QgsDistanceArea()
        self.measurer.setEllipsoid(QgsProject.instance().ellipsoid())

    def _snap(self, event):
        match = self.canvas.snappingUtils().snapToMap(event.pos())
        if match.isValid():
            return QgsPointXY(match.point())
        return self.toMapCoordinates(event.pos())

    def canvasPressEvent(self, event):
        if event.button() != Qt.LeftButton:
            self.reset()
            return
        point = self._snap(event)
        if self.start_point is None:
            self.start_point = point
            self.rubber_band.reset(QgsWkbTypes.LineGeometry)
        else:
            dist = self.measurer.measureLine(self.start_point, point)
            self.iface.messageBar().pushInfo("Cadastru", f"Distanta: {dist:.3f} m")
            self.reset()

    def canvasMoveEvent(self, event):
        if self.start_point is None:
            return
        point = self._snap(event)
        self.rubber_band.setToGeometry(
            QgsGeometry.fromPolylineXY([self.start_point, point]), None
        )

    def reset(self):
        self.start_point = None
        self.rubber_band.reset(QgsWkbTypes.LineGeometry)

    def deactivate(self):
        self.reset()
        super().deactivate()
