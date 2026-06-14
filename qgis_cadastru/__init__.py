# Punctul de intrare al plugin-ului QGIS.
# QGIS apeleaza classFactory(iface) la incarcarea plugin-ului si primeste
# obiectul `iface` (QgisInterface) prin care plugin-ul controleaza aplicatia.


def classFactory(iface):
    """Creeaza instanta plugin-ului de cadastru.

    :param iface: Interfata QGIS prin care manipulam UI-ul si harta.
    :type iface: qgis.gui.QgisInterface
    """
    from .cadastru_plugin import CadastruPlugin

    return CadastruPlugin(iface)
