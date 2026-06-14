# Interpretarea comenzilor in limbaj natural prin Claude (Anthropic).
#
# Utilizatorul scrie liber in linia de comanda ("deseneaza o parcela noua",
# "cat e distanta pana aici", "adu imobilele din e-CAD"). Trimitem textul lui
# Claude impreuna cu lista comenzilor disponibile expuse ca TOOL-uri (function
# calling). Claude alege EXACT una dintre comenzile reale ale aplicatiei, deci
# nu poate inventa actiuni in afara celor implementate.
#
# Folosim SDK-ul oficial `anthropic` (Python). Apelul de retea este sincron aici
# si se ruleaza intr-un thread separat de catre ui/command_line.py, ca sa nu
# blocheze interfata QGIS.

import os

from qgis.PyQt.QtCore import QSettings

# Grup de setari pentru configurarea AI (cheie API, model).
AI_SETTINGS_GROUP = "e-cad-cadastru/ai"

# Modelul implicit: cel mai capabil model Claude la momentul scrierii.
# Configurabil prin QSettings sau variabila de mediu ANTHROPIC_MODEL.
DEFAULT_MODEL = "claude-opus-4-8"

SYSTEM_PROMPT = (
    "Esti asistentul de comanda al unei aplicatii de cadastru construite peste "
    "QGIS, cu interfata in stil AutoCAD. Utilizatorul scrie in limbaj natural "
    "(in romana) ce vrea sa faca. Alege EXACT o singura unealta care corespunde "
    "intentiei lui. Daca nicio unealta nu se potriveste sau cererea este "
    "ambigua, foloseste unealta 'ask_clarification' pentru a cere o lamurire "
    "scurta. Nu raspunde cu text liber in afara apelurilor de unelte."
)


class AiUnavailable(Exception):
    """Ridicata cand interpretarea AI nu poate fi folosita (lipsa SDK / cheie)."""


class AiCommandInterpreter:
    """Traduce o comanda in limbaj natural in numele unei actiuni a aplicatiei.

    :param commands: lista de comenzi (dict cu 'name' si 'description'),
                     vezi CadastruPlugin._commands().
    """

    def __init__(self, commands):
        self.commands = commands
        self._client = None  # creat lenes la prima utilizare

    # ------------------------------------------------------------------
    # Configurare
    # ------------------------------------------------------------------
    def _setting(self, key, env_var, default=""):
        s = QSettings()
        s.beginGroup(AI_SETTINGS_GROUP)
        value = s.value(key, os.environ.get(env_var, default))
        s.endGroup()
        return value

    def api_key(self):
        return self._setting("api_key", "ANTHROPIC_API_KEY", "")

    def model(self):
        return self._setting("model", "ANTHROPIC_MODEL", DEFAULT_MODEL)

    def is_configured(self):
        """True daca exista SDK-ul si o cheie API (verificare rapida, fara retea)."""
        try:
            import anthropic  # noqa: F401
        except ImportError:
            return False
        return bool(self.api_key())

    # ------------------------------------------------------------------
    # Client + unelte
    # ------------------------------------------------------------------
    def _get_client(self):
        try:
            import anthropic
        except ImportError as exc:
            raise AiUnavailable(
                "Biblioteca 'anthropic' nu este instalata in mediul Python al "
                "QGIS. Instaleaza-o cu: python3 -m pip install anthropic"
            ) from exc

        key = self.api_key()
        if not key:
            raise AiUnavailable(
                "Cheia API Anthropic lipseste. Seteaz-o in variabila de mediu "
                "ANTHROPIC_API_KEY sau in setarile plugin-ului (grup "
                f"'{AI_SETTINGS_GROUP}')."
            )

        if self._client is None:
            self._client = anthropic.Anthropic(api_key=key)
        return self._client

    def _tools(self):
        """Construieste lista de tool-uri pentru Claude din comenzile aplicatiei."""
        tools = []
        for cmd in self.commands:
            tools.append(
                {
                    "name": cmd["name"],
                    "description": cmd["description"],
                    # Comenzile actuale nu au parametri; schema goala.
                    "input_schema": {
                        "type": "object",
                        "properties": {},
                        "additionalProperties": False,
                    },
                }
            )

        # Unealta de rezerva pentru intentii neacoperite / ambigue.
        tools.append(
            {
                "name": "ask_clarification",
                "description": (
                    "Foloseste cand intentia utilizatorului nu corespunde niciunei "
                    "comenzi disponibile sau este neclara. Returneaza o intrebare "
                    "scurta de lamurire."
                ),
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "intrebare": {
                            "type": "string",
                            "description": "Intrebarea de lamurire, in romana.",
                        }
                    },
                    "required": ["intrebare"],
                    "additionalProperties": False,
                },
            }
        )
        return tools

    # ------------------------------------------------------------------
    # Interpretare (apel de retea — a se rula intr-un thread separat)
    # ------------------------------------------------------------------
    def interpret(self, text):
        """Returneaza (nume_actiune, input_dict) pentru textul dat.

        - nume_actiune = numele unei comenzi (ex. 'parcela') sau 'ask_clarification'
        - input_dict   = argumentele alese de model (gol pentru comenzile actuale)
        """
        client = self._get_client()

        message = client.messages.create(
            model=self.model(),
            max_tokens=1024,
            system=SYSTEM_PROMPT,
            tools=self._tools(),
            # Forteaza alegerea unei unelte (nu raspuns text liber).
            tool_choice={"type": "any"},
            # Rutare rapida: nu e nevoie de rationament adanc pentru clasificare.
            output_config={"effort": "low"},
            messages=[{"role": "user", "content": text}],
        )

        for block in message.content:
            if block.type == "tool_use":
                return block.name, dict(block.input or {})

        # Teoretic imposibil cu tool_choice="any", dar tratam defensiv.
        return None, {}
