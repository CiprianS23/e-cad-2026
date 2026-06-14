# Linia de comanda in stil AutoCAD.
# Un dock jos cu istoric + camp de input. Utilizatorul tasteaza comenzi scurte
# (ex. "PA" pentru parcela, "DI" pentru distanta) la fel ca in AutoCAD, iar
# comanda este rutata catre actiunea corespunzatoare din registry.

from qgis.PyQt.QtCore import Qt
from qgis.PyQt.QtWidgets import (
    QDockWidget,
    QWidget,
    QVBoxLayout,
    QPlainTextEdit,
    QLineEdit,
)


class CommandLineDock(QDockWidget):
    """Dock cu linie de comanda tip AutoCAD.

    :param iface: interfata QGIS (pentru mesaje in bara de stare).
    :param registry: dict {tuple(alias-uri): callable}.
    """

    def __init__(self, iface, registry):
        super().__init__("Linie de comanda", iface.mainWindow())
        self.iface = iface
        self.setObjectName("CadastruCommandDock")

        # Construieste un index plat alias -> callable, plus lista de nume canonice.
        self._index = {}
        self._canonical = []
        for aliases, callback in registry.items():
            self._canonical.append(aliases[0])
            for alias in aliases:
                self._index[alias.lower()] = callback

        self._history_index = None
        self._history = []

        self._build_ui()

    def _build_ui(self):
        container = QWidget()
        layout = QVBoxLayout(container)
        layout.setContentsMargins(2, 2, 2, 2)
        layout.setSpacing(2)

        self.history_view = QPlainTextEdit()
        self.history_view.setObjectName("CadastruCommandHistory")
        self.history_view.setReadOnly(True)
        self.history_view.setMaximumHeight(120)
        self.history_view.setPlainText(
            "e-CAD Cadastru — tasteaza o comanda si Enter. "
            "Scrie ? pentru lista de comenzi."
        )

        self.input = QLineEdit()
        self.input.setObjectName("CadastruCommandInput")
        self.input.setPlaceholderText("Comanda:")
        self.input.returnPressed.connect(self._on_enter)
        self.input.installEventFilter(self)

        layout.addWidget(self.history_view)
        layout.addWidget(self.input)
        self.setWidget(container)

    # ------------------------------------------------------------------
    def _log(self, text):
        self.history_view.appendPlainText(text)

    def _on_enter(self):
        raw = self.input.text().strip()
        self.input.clear()
        if not raw:
            return

        self._history.append(raw)
        self._history_index = None

        cmd = raw.lower()
        self._log("> " + raw)

        if cmd in ("?", "help", "ajutor"):
            self._log("Comenzi disponibile: " + ", ".join(sorted(self._canonical)))
            return

        callback = self._index.get(cmd)
        if callback is None:
            self._log(f"Comanda necunoscuta: '{raw}'. Scrie ? pentru lista.")
            self.iface.messageBar().pushWarning("Cadastru", f"Comanda necunoscuta: {raw}")
            return

        try:
            callback()
            self._log(f"OK: {cmd}")
        except Exception as exc:  # noqa: BLE001 - raportam orice eroare in linia de comanda
            self._log(f"Eroare la '{cmd}': {exc}")
            self.iface.messageBar().pushCritical("Cadastru", str(exc))

    # ------------------------------------------------------------------
    def eventFilter(self, obj, event):
        """Sageti sus/jos parcurg istoricul comenzilor, ca in AutoCAD."""
        if obj is self.input and event.type() == event.KeyPress:
            if event.key() == Qt.Key_Up:
                self._recall(-1)
                return True
            if event.key() == Qt.Key_Down:
                self._recall(1)
                return True
        return super().eventFilter(obj, event)

    def _recall(self, direction):
        if not self._history:
            return
        if self._history_index is None:
            self._history_index = len(self._history)
        self._history_index = max(0, min(len(self._history) - 1, self._history_index + direction))
        self.input.setText(self._history[self._history_index])
