# Conexiunea catre baza de date e-CAD (PostgreSQL/PostGIS).
#
# Aplicatia e-CAD stocheaza imobilele cadastrale cu geometrie in stratul cgxml
# (tabela f_cg_land) si parcelele administrative in stratul RO (tabela parcela).
# Aici incarcam aceste tabele ca straturi QGIS PostGIS, read-only implicit, ca
# specialistul sa lucreze peste datele reale fara sa atinga productia din greseala.
#
# Parametrii conexiunii se citesc din QSettings (configurabili in UI), cu valori
# implicite din variabile de mediu pentru dezvoltare locala.

import os

from qgis.PyQt.QtCore import QSettings
from qgis.core import QgsVectorLayer, QgsProject, QgsDataSourceUri

SETTINGS_GROUP = "e-cad-cadastru/db"


class EcadConnection:
    """Gestioneaza conexiunea PostGIS catre baza e-CAD si incarcarea straturilor."""

    def __init__(self):
        self.settings = QSettings()

    # ------------------------------------------------------------------
    def params(self):
        """Parametrii de conexiune, din QSettings cu fallback pe mediu."""
        s = self.settings
        s.beginGroup(SETTINGS_GROUP)
        params = {
            "host": s.value("host", os.environ.get("ECAD_DB_HOST", "localhost")),
            "port": s.value("port", os.environ.get("ECAD_DB_PORT", "5432")),
            "dbname": s.value("dbname", os.environ.get("ECAD_DB_NAME", "ecad_development")),
            "user": s.value("user", os.environ.get("ECAD_DB_USER", "postgres")),
            "password": s.value("password", os.environ.get("ECAD_DB_PASSWORD", "")),
        }
        s.endGroup()
        return params

    def _uri(self, schema, table, geom_column, key_column, where=""):
        p = self.params()
        uri = QgsDataSourceUri()
        uri.setConnection(p["host"], str(p["port"]), p["dbname"], p["user"], p["password"])
        uri.setDataSource(schema, table, geom_column, where, key_column)
        return uri

    # ------------------------------------------------------------------
    def load_parcele_layer(self, iface, comuna_id=None):
        """Incarca imobilele cadastrale (f_cg_land) ca strat PostGIS.

        Filtreaza optional pe comuna (multi-tenant prin comuna_id).
        """
        where = f"comuna_id = {int(comuna_id)}" if comuna_id else ""
        # NOTA: numele coloanei de geometrie pe f_cg_land trebuie confirmat din
        # schema reala e-CAD (vezi CLAUDE.md, sectiunea "De aflat din schema reala").
        uri = self._uri("public", "f_cg_land", "geom", "id", where)
        layer = QgsVectorLayer(uri.uri(False), "Imobile (e-CAD)", "postgres")

        if not layer.isValid():
            iface.messageBar().pushCritical(
                "Cadastru",
                "Nu s-a putut incarca stratul de imobile din e-CAD. "
                "Verifica parametrii conexiunii si numele coloanei de geometrie.",
            )
            return None

        QgsProject.instance().addMapLayer(layer)
        iface.messageBar().pushInfo("Cadastru", "Strat imobile e-CAD incarcat.")
        return layer
