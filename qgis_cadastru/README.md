# e-CAD Cadastru — aplicație de cadastru în stil AutoCAD, peste QGIS

Plugin QGIS (Python / PyQGIS) care transformă QGIS într-un mediu de lucru
**cadastral** cu UX inspirat din **AutoCAD**: temă întunecată, linie de comandă,
toolbar de desen și puncte de integrare cu aplicația **e-CAD**.

> **De ce plugin și nu fork de QGIS?**
> QGIS este ~GB de C++/Qt sub licență GPL v2+. Un plugin Python obține 90% din
> rezultat (UI focalizat pe cadastru, unelte proprii) **fără compilare C++** și
> rămâne ușor de actualizat la versiuni noi de QGIS. Forkul complet al sursei
> rămâne o opțiune dacă vreodată e nevoie de modificări în nucleul C++.

## Ce face

- **Temă AutoCAD-like** — fundal întunecat pe canvas (model space), paletă gri,
  linie de comandă monospaced (`ui/theme.py`, `resources/theme.qss`).
- **Profil curat** — ascunde meniurile/toolbar-urile GIS generale irelevante în
  cadastru (Web, Raster, Database…), reversibil (`profile/profile_cleanup.py`).
- **Toolbar de cadastru** — desen parcelă cu snapping, măsurători
  (`tools/draw_parcela.py`, `tools/measure.py`).
- **Linie de comandă tip AutoCAD** — tastezi `PA` (parcelă), `DI` (distanță),
  `ZE` (zoom extent)… cu istoric pe săgeți (`ui/command_line.py`).
- **Integrare e-CAD** — încarcă imobile/parcele din PostGIS, schelet export
  `cgxml` ANCPI (`ecad/connection.py`, `ecad/cgxml.py`).

## Structură

```
qgis_cadastru/
├── metadata.txt              # metadata plugin QGIS
├── __init__.py               # classFactory(iface)
├── cadastru_plugin.py        # clasa principala (orchestreaza tot)
├── ui/
│   ├── theme.py              # tema AutoCAD-like
│   └── command_line.py       # linia de comanda
├── profile/
│   └── profile_cleanup.py    # ascunde UI irelevant (reversibil)
├── tools/
│   ├── draw_parcela.py       # desen parcela cu snapping
│   └── measure.py            # masurare distanta
├── ecad/
│   ├── connection.py         # conexiune PostGIS e-CAD
│   └── cgxml.py              # export/import cgxml (stub)
├── resources/
│   └── theme.qss             # stylesheet Qt
└── scripts/
    └── extract_to_repo.sh    # desprinde folderul intr-un repo separat
```

## Instalare (dezvoltare)

QGIS caută plugin-urile în folderul de profil. Leagă acest folder acolo:

```bash
# Linux
ln -s "$(pwd)/qgis_cadastru" \
  ~/.local/share/QGIS/QGIS3/profiles/default/python/plugins/qgis_cadastru

# macOS
ln -s "$(pwd)/qgis_cadastru" \
  ~/Library/Application\ Support/QGIS/QGIS3/profiles/default/python/plugins/qgis_cadastru
```

Apoi în QGIS: *Plugins → Manage and Install Plugins → Installed* și bifează
**e-CAD Cadastru**. (Plugin marcat `experimental=True` — activează „Show
experimental plugins" în setări.)

## Configurare conexiune e-CAD

Parametrii PostGIS se citesc din `QSettings` (grup `e-cad-cadastru/db`), cu
fallback pe variabile de mediu pentru dezvoltare:

```bash
export ECAD_DB_HOST=localhost ECAD_DB_PORT=5432 \
       ECAD_DB_NAME=ecad_development ECAD_DB_USER=postgres ECAD_DB_PASSWORD=...
```

> Numele coloanei de geometrie pe `f_cg_land` trebuie confirmat din schema reală
> e-CAD (vezi `CLAUDE.md` din repo-ul principal, „De aflat din schema reală").

## Desprindere în repo separat

Acest cod trăiește temporar în subfolderul `qgis_cadastru/` din repo-ul Rails
`e-cad-2026` (mediul curent nu permite crearea unui repo nou prin API). Când
creezi repo-ul gol `e-cad-qgis` pe GitHub, rulează:

```bash
qgis_cadastru/scripts/extract_to_repo.sh git@github.com:CiprianS23/e-cad-qgis.git
```

## Licență

GPL v2+ (derivat din API-ul QGIS). Vezi `LICENSE`.
