# Export/import cgxml (schema ANCPI) — punte intre desenul din QGIS si livrabilul legal.
#
# cgxml este formatul standardizat ANCPI pentru cadastru general (vezi CLAUDE.md,
# stratul CGXML: f_cg_land, f_cg_parcel, f_cg_building, f_cg_person, f_cg_deed...).
# Exportul catre ANCPI este o cerinta legala, deci fidelitatea schemei e obligatorie.
#
# Acest modul este deocamdata un STUB cu structura clara: definim contractul si
# pasii, urmand ca generarea efectiva a XML-ului sa reutilizeze logica validata
# deja existenta in aplicatia Rails e-CAD (sau sa o reimplementam 1:1, cu teste
# de validare contra "Reguli validare fisier cgxml.pdf").

from qgis.core import QgsProject


def export_current_selection(iface):
    """Exporta features selectate in format cgxml.

    Pasi (de implementat):
      1. Identifica stratul de imobile activ si features selectate.
      2. Mapeaza geometria + atributele in entitatile cgxml (land/parcel/person).
      3. Genereaza XML-ul conform schemei ANCPI.
      4. Valideaza contra regulilor (vezi "Reguli validare fisier cgxml.pdf").
      5. Scrie fisierul si raporteaza erorile de validare in messageBar.
    """
    layer = iface.activeLayer()
    if layer is None:
        iface.messageBar().pushWarning("Cadastru", "Selecteaza un strat de imobile mai intai.")
        return

    selected = layer.selectedFeatureCount() if hasattr(layer, "selectedFeatureCount") else 0
    iface.messageBar().pushInfo(
        "Cadastru",
        f"Export cgxml: {selected} imobile selectate. "
        "(TODO: generare XML conform schemei ANCPI si validare.)",
    )
    # TODO: reutilizeaza generatorul cgxml din e-CAD (Rails) prin API, sau
    #       reimplementeaza maparea aici cu teste contra schemei oficiale.


def import_cgxml(iface, path):
    """Importa un fisier cgxml ca strat(uri) in proiect.

    Pasi (de implementat):
      1. Parseaza XML-ul (land, parcel, building, person, deed).
      2. Construieste geometrii QGIS din coordonate (CRS EPSG:3844 - Stereo70).
      3. Creeaza un strat memorie/GeoPackage cu atributele relevante.
    """
    raise NotImplementedError(
        "Import cgxml: de implementat parserul XML -> straturi QGIS (EPSG:3844)."
    )
