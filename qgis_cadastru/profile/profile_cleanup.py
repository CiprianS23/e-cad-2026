# Ascunde elementele de UI generale ale QGIS care nu sunt utile in cadastru,
# ca aplicatia sa para focalizata (mai aproape de AutoCAD decat de un GIS complet).
#
# Strategie: NU stergem nimic permanent. Doar setam visible=False pe toolbar-urile
# si meniurile vizate, retinem starea anterioara si o restauram la unload().
#
# Lista de obiecte ascunse este conservatoare si configurabila. Numele de obiecte
# (objectName) sunt cele standard din QGIS; cele care nu exista sunt ignorate.

from qgis.PyQt.QtWidgets import QToolBar, QMenu

# Toolbar-uri standard QGIS de ascuns (objectName). Pastram doar ce e relevant.
HIDDEN_TOOLBARS = [
    "mWebToolBar",          # plugin-uri web
    "mLabelToolBar",        # etichetare avansata
    "mPluginToolBar",       # bara generica de plugin-uri
    "mRasterToolBar",       # operatii raster (rar in cadastru pur)
    "mHelpToolBar",
    "mVectorToolBar",
]

# Meniuri din bara de meniu de ascuns (dupa titlu, fara accelerator).
HIDDEN_MENUS = [
    "&Web",
    "&Raster",
    "&Database",
    "&Internet",   # variante de localizare
]


class ProfileCleaner:
    """Ascunde/restaureaza elemente standard de UI pentru un profil de cadastru."""

    def __init__(self, iface):
        self.iface = iface
        self._hidden_toolbars = []   # (toolbar, prev_visible)
        self._hidden_menus = []      # (action_in_menubar, prev_visible)

    def apply(self):
        main_window = self.iface.mainWindow()

        # Toolbar-uri.
        for toolbar in main_window.findChildren(QToolBar):
            if toolbar.objectName() in HIDDEN_TOOLBARS:
                self._hidden_toolbars.append((toolbar, toolbar.isVisible()))
                toolbar.setVisible(False)

        # Meniuri din bara de meniu.
        menubar = main_window.menuBar()
        for action in menubar.actions():
            menu = action.menu()
            if menu is None:
                continue
            if menu.title() in HIDDEN_MENUS:
                self._hidden_menus.append((action, action.isVisible()))
                action.setVisible(False)

    def restore(self):
        for toolbar, prev in self._hidden_toolbars:
            toolbar.setVisible(prev)
        self._hidden_toolbars = []

        for action, prev in self._hidden_menus:
            action.setVisible(prev)
        self._hidden_menus = []
