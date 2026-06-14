# Linia de comanda in limbaj natural, in stil AutoCAD.
#
# Un dock jos cu istoric + camp de input. Utilizatorul poate:
#   - tasta o scurtatura tip AutoCAD (ex. "PA", "DI") -> executie imediata, local
#   - scrie liber ce vrea ("deseneaza o parcela", "cat e distanta") -> trimitem
#     textul lui Claude care alege actiunea potrivita (vezi ecad/ai.py)
#
# Apelul catre Claude este de retea, deci ruleaza intr-un QThread separat ca sa
# nu blocheze interfata QGIS. Rezultatul revine prin semnale Qt.

from qgis.PyQt.QtCore import Qt, QThread, QObject, pyqtSignal
from qgis.PyQt.QtWidgets import (
    QDockWidget,
    QWidget,
    QVBoxLayout,
    QPlainTextEdit,
    QLineEdit,
)

from ..ecad.ai import AiCommandInterpreter, AiUnavailable


class _AiWorker(QObject):
    """Worker care ruleaza interpretarea AI (apel de retea) pe un thread separat."""

    finished = pyqtSignal(str, object)  # (nume_actiune, input_dict)
    failed = pyqtSignal(str)            # mesaj de eroare

    def __init__(self, interpreter, text):
        super().__init__()
        self.interpreter = interpreter
        self.text = text

    def run(self):
        try:
            name, params = self.interpreter.interpret(self.text)
            self.finished.emit(name or "", params or {})
        except AiUnavailable as exc:
            self.failed.emit(str(exc))
        except Exception as exc:  # noqa: BLE001 - raportam orice eroare in linie
            self.failed.emit(f"Eroare AI: {exc}")


class CommandLineDock(QDockWidget):
    """Dock cu linie de comanda in limbaj natural.

    :param iface: interfata QGIS (pentru mesaje in bara de stare).
    :param commands: lista de comenzi (vezi CadastruPlugin._commands()).
    """

    def __init__(self, iface, commands):
        super().__init__("Linie de comanda", iface.mainWindow())
        self.iface = iface
        self.setObjectName("CadastruCommandDock")

        self.commands = commands
        # Index pentru executie rapida (alias/nume exact -> callback).
        self._by_name = {c["name"]: c["callback"] for c in commands}
        self._alias_index = {}
        for cmd in commands:
            for alias in [cmd["name"]] + cmd.get("aliases", []):
                self._alias_index[alias.lower()] = cmd["callback"]

        self.interpreter = AiCommandInterpreter(commands)

        self._history = []
        self._history_index = None

        # Thread/worker AI tinute ca atribute cat timp ruleaza.
        self._thread = None
        self._worker = None

        self._build_ui()

    # ------------------------------------------------------------------
    def _build_ui(self):
        container = QWidget()
        layout = QVBoxLayout(container)
        layout.setContentsMargins(2, 2, 2, 2)
        layout.setSpacing(2)

        self.history_view = QPlainTextEdit()
        self.history_view.setObjectName("CadastruCommandHistory")
        self.history_view.setReadOnly(True)
        self.history_view.setMaximumHeight(140)
        intro = (
            "e-CAD Cadastru — scrie ce vrei sa faci, in limbaj natural "
            "(ex. \"deseneaza o parcela noua\" sau \"masoara distanta\"). "
            "Poti folosi si scurtaturi: " + ", ".join(self._short_list()) + ". "
            "Scrie ? pentru ajutor."
        )
        self.history_view.setPlainText(intro)

        self.input = QLineEdit()
        self.input.setObjectName("CadastruCommandInput")
        self.input.setPlaceholderText("Comanda:")
        self.input.returnPressed.connect(self._on_enter)
        self.input.installEventFilter(self)

        layout.addWidget(self.history_view)
        layout.addWidget(self.input)
        self.setWidget(container)

    def _short_list(self):
        return [c["aliases"][0].upper() for c in self.commands if c.get("aliases")]

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
        self._log("> " + raw)

        lowered = raw.lower()

        # Ajutor.
        if lowered in ("?", "help", "ajutor"):
            self._log("Comenzi disponibile:")
            for cmd in self.commands:
                aliases = "/".join(cmd.get("aliases", [])) or cmd["name"]
                self._log(f"  [{aliases}] {cmd['description']}")
            self._log("  Sau scrie liber, in limbaj natural.")
            return

        # Fast-path: scurtatura/nume exact -> executie imediata, fara API.
        callback = self._alias_index.get(lowered)
        if callback is not None:
            self._run_callback(lowered, callback)
            return

        # Altfel: limbaj natural -> interpretare prin Claude (in thread separat).
        self._interpret_async(raw)

    # ------------------------------------------------------------------
    def _run_callback(self, label, callback):
        try:
            callback()
            self._log(f"OK: {label}")
        except Exception as exc:  # noqa: BLE001
            self._log(f"Eroare la '{label}': {exc}")
            self.iface.messageBar().pushCritical("Cadastru", str(exc))

    # ------------------------------------------------------------------
    # Interpretare AI asincrona
    # ------------------------------------------------------------------
    def _interpret_async(self, text):
        if self._thread is not None:
            self._log("... astept raspunsul anterior, reincearca imediat.")
            return

        if not self.interpreter.is_configured():
            self._log(
                "AI indisponibil: instaleaza 'anthropic' si seteaza "
                "ANTHROPIC_API_KEY. Pana atunci, foloseste scurtaturile (scrie ?)."
            )
            return

        self._log("... interpretez cererea")
        self.input.setEnabled(False)

        self._thread = QThread(self)
        self._worker = _AiWorker(self.interpreter, text)
        self._worker.moveToThread(self._thread)

        self._thread.started.connect(self._worker.run)
        self._worker.finished.connect(self._on_ai_finished)
        self._worker.failed.connect(self._on_ai_failed)
        # Curatare thread dupa terminare (succes sau eroare).
        self._worker.finished.connect(self._cleanup_thread)
        self._worker.failed.connect(self._cleanup_thread)

        self._thread.start()

    def _on_ai_finished(self, name, params):
        if not name:
            self._log("Nu am putut interpreta cererea. Reformuleaza, te rog.")
            return

        if name == "ask_clarification":
            question = (params or {}).get("intrebare", "Poti detalia cererea?")
            self._log("? " + question)
            return

        callback = self._by_name.get(name)
        if callback is None:
            self._log(f"Actiune necunoscuta interpretata: '{name}'.")
            return

        self._log(f"Interpretat ca: {name}")
        self._run_callback(name, callback)

    def _on_ai_failed(self, message):
        self._log(message)
        self.iface.messageBar().pushWarning("Cadastru", message)

    def _cleanup_thread(self):
        self.input.setEnabled(True)
        self.input.setFocus()
        if self._thread is not None:
            self._thread.quit()
            self._thread.wait()
            self._thread = None
        self._worker = None

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
        self._history_index = max(
            0, min(len(self._history) - 1, self._history_index + direction)
        )
        self.input.setText(self._history[self._history_index])
