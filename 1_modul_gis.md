# MODUL GIS — SPECIFICAȚIE TEHNICĂ COMPLETĂ

## Sistem Cadastru Sistematic — Înregistrare Imobile

-----

## 1. FILOZOFIA MODULULUI GIS

### 1.1 Principiul fundamental — “CAD feel în browser”

Interfața GIS trebuie să arate și să se comporte familiar pentru un specialist în cadastru
obișnuit cu AutoCAD/TopoCad. Obiectivul nu este să înlocuiască CAD-ul, ci să ofere
un mediu integrat care elimină necesitatea sincronizării manuale între aplicații.

```
MENTALITATEA CAD (familiară)      IMPLEMENTARE WEBGIS
────────────────────────────────────────────────────────
Coordonate exacte Stereo70    →   Afișare nativă Stereo70
Snap la punct                 →   Snap system complet
Ortho mode (F8)               →   Toggle ortho identic
Linie de comandă              →   Input coordonate directe
Layer Manager                 →   Panel layere identic
Toolbar cu iconițe            →   Toolbar CAD-like
```

### 1.2 Principiul Single Source of Truth

```
BAZA DE DATE PostgreSQL/PostGIS
        ↑↓ sincronizare bidirecțională în timp real
INTERFAȚA GRAFICĂ (hartă + formulare)

Orice modificare în BD  → apare instant pe hartă
Orice modificare pe hartă → salvată instant în BD
```

### 1.3 Filozofia “Import All First”

Spre deosebire de e-CAD (introducere manuală pas cu pas), noul sistem permite
importul masiv inițial al tuturor datelor disponibile, sistemul organizând și
structurând automat datele importate.

-----

## 2. ARHITECTURA TEHNICĂ

### 2.1 Stack tehnologic GIS

```
FRONTEND
├── OpenLayers 9           — motor hartă principal
├── ol-ext                 — instrumente editare avansate (CAD-like)
├── jsts                   — calcule geometrice în browser
│   └── (Java Topology Suite — același motor ca PostGIS)
├── dxf-parser             — import DXF direct în browser
├── proj4js                — conversii sistem de proiecție
│   └── Stereo70 (EPSG:3844) ↔ WGS84 (EPSG:4326)
└── Tailwind CSS           — stilizare interfață

BACKEND
├── Ruby on Rails 7.1+     — framework aplicație
├── PostgreSQL 15+         — baza de date principală
├── PostGIS 3.x            — extensie spațială
├── ActionCable            — WebSocket sincronizare real-time
├── Sidekiq                — procesare asincronă
└── Redis                  — coadă joburi + cache

SERVERE EXTERNE
├── MapProxy               — server tiles ortofotoplan (Hetzner, existent)
├── GeoServer              — servire straturi WMS/WFS
└── Claude API             — procesare AI (OCR, validare, detectare direcție)
```

### 2.2 Sistemul de proiecție

**Toate coordonatele se stochează în EPSG:3844 (Stereo70).**

- Interfața afișează MEREU coordonate Stereo70
- Conversia WGS84 ↔ Stereo70 este transparentă, în background
- Utilizatorul nu știe că există conversie
- Export → Stereo70
- Import coordonate → acceptă Stereo70 nativ

```sql
-- Coloana geometrie în baza de date
geom GEOMETRY(MultiPolygon, 3844)

-- Index spatial obligatoriu
CREATE INDEX imobile_geom_idx ON imobile USING GIST(geom);
```

-----

## 3. INTERFAȚA GRAFICĂ — LAYOUT COMPLET

### 3.1 Structura ecranului

```
┌────────────────────────────────────────────────────────┐
│  BARA MENIU (ca AutoCAD)                               │
│  Fișier  Editare  Vizualizare  Instrumente  Ajutor    │
├────────────────────────────────────────────────────────┤
│  BARA INSTRUMENTE (toolbar, iconițe CAD-like)          │
│  [↖][✥][🔍+][🔍-][⊡][📐][⬡][✏][⊢][⊣][⌖][⟳][💾]   │
├──────────────────┬─────────────────────────────────────┤
│  PANEL LAYERE    │                                     │
│  (ca Layer Mgr)  │                                     │
│  ┌────────────┐  │                                     │
│  │☑ CF_exist  │  │      VIEWPORT PRINCIPAL             │
│  │☑ Ortofoto  │  │      (zona de desen/hartă)          │
│  │☑ Masur_TXT │  │                                     │
│  │☑ Limite_UAT│  │                                     │
│  │☐ Plan_vechi│  │                                     │
│  │☑ Parcele   │  │                                     │
│  └────────────┘  │                                     │
│  PROPRIETĂȚI     │                                     │
│  ┌────────────┐  │                                     │
│  │Culoare: ██ │  │                                     │
│  │Grosime: 0.5│  │                                     │
│  │Tip linie:─ │  │                                     │
│  └────────────┘  │                                     │
├──────────────────┴─────────────────────────────────────┤
│  LINIE DE COMANDĂ (ca în AutoCAD)                      │
│  > Comandă: _SNAP ON  Toleranță: 0.05m                │
│  > Punct 1: X: 587432.123  Y: 345678.456              │
│  > Specificați următorul punct:                        │
├────────────────────────────────────────────────────────┤
│  STATUS BAR                                            │
│  SNAP●  ORTHO○  GRID○  │ X:587432.123 Y:345678.456   │
│  Stereo70  Scară:1/500  │ Suprafață: 2450.23 mp       │
└────────────────────────────────────────────────────────┘
```

### 3.2 Panel stânga — Lista imobile

```
┌──────────────────┐
│ LISTA IMOBILE    │
│ ──────────────── │
│ 🔴 T15/P123      │  ← Fără geometrie (prioritate)
│   Fără geom     │
│ 🟡 T15/P124      │  ← În lucru
│   In lucru      │
│ 🟢 T15/P125      │  ← Validat
│   Validat       │
│                  │
│ FILTRE           │
│ ☑ Fără geom     │
│ ☑ In lucru      │
│ ☑ Validat       │
│                  │
│ CĂUTARE          │
│ [__________]     │
└──────────────────┘
```

### 3.3 Panel dreapta — Proprietăți entitate

Click pe orice parcelă → panel cu date complete:

```
┌─────────────────────────────┐
│  PROPRIETĂȚI IMOBIL         │
│  ─────────────────────────  │
│  Layer:    LIMITE_IMOBILE   │
│  Tip:      Poligon          │
│  ─────────────────────────  │
│  CADASTRU                   │
│  Nr. CF:   12345            │
│  Nr. Cad:  A1234/1          │
│  Supraf.:  2450.23 mp       │
│  Suprf.act:2450.00 mp       │
│  Diferență:+0.23 mp ✓      │
│  ─────────────────────────  │
│  PROPRIETAR                 │
│  Nume:  Ion Ionescu         │
│  CNP:   **********123       │
│  ─────────────────────────  │
│  GEOMETRIE                  │
│  Vertices: 6                │
│  Perimetru:201.34 m         │
│  ─────────────────────────  │
│  [Editează] [Vezi CF]       │
│  [Zoom la imobil]           │
└─────────────────────────────┘
```

-----

## 4. SISTEMUL DE LAYERE

### 4.1 Layere predefinite (create automat la proiect nou)

|Layer            |Culoare      |Stare implicită|Descriere                               |
|-----------------|-------------|---------------|----------------------------------------|
|CF_EXISTENTE     |Galben       |Vizibil, Blocat|Geometrii din CGXML importat — referință|
|LIMITE_UAT       |Roșu, gros   |Vizibil, Blocat|Limita UAT                              |
|MASURATORI_PUNCTE|Verde        |Vizibil        |Puncte TXT din stație totală            |
|MASURATORI_LINII |Verde deschis|Vizibil        |Linii din DXF CAD                       |
|LIMITE_IMOBILE   |Alb/Negru    |Vizibil, Activ |Poligoane finale — layer de desenare    |
|CONSTRUCTII      |Magenta      |Vizibil        |Amprentele construcțiilor               |
|DRUMURI          |Gri          |Vizibil        |Rețea stradală                          |
|APE              |Albastru     |Vizibil        |Cursuri de apă                          |
|ORTOFOTO         |—            |Background     |MapProxy — serverul existent Hetzner    |
|PLAN_VECHI       |Sepia, 50%   |Oprit implicit |Planuri raster georeferențiate          |

### 4.2 Proprietăți per layer (identic AutoCAD Layer Manager)

- Vizibilitate (on/off)
- Lock (blocat/editabil)
- Culoare per layer
- Tip linie per layer (continuă, punctată, linie-punct)
- Grosime linie per layer
- Layer curent selectabil

-----

## 5. SISTEM SNAP — DETALII TEHNICE

### 5.1 Tipuri de snap

```
├── Snap la punct măsurat TXT    ← CEL MAI IMPORTANT
├── Snap la endpoint entitate
├── Snap la midpoint
├── Snap la intersecție
├── Snap la perpendiculară
├── Snap la nearest (cel mai aproape)
└── Snap la centroid poligon
```

### 5.2 Indicator vizual snap

- X galben (identic AutoCAD) la punctul de snap activ
- Coordonatele exacte afișate în status bar în timp real
- Toleranță snap configurabilă (implicit: 0.05m)

### 5.3 Configurare snap

```
PARAMETRI CONFIGURABILI per proiect
├── Snap tolerance: 0.05m (implicit)
│   └── Vertices mai apropiate → unite automat
├── Sliver threshold: 0.10mp
│   └── Suprapuneri sub prag → eliminate automat
└── Gap threshold: 0.10mp
    └── Goluri sub prag → atribuite automat
```

-----

## 6. NAVIGARE — IDENTIC AUTOCAD

```
Scroll mouse              → zoom in/out
Click mijloc + drag       → pan
Double-click mijloc       → zoom extents
Rotița + Shift            → zoom la fereastră
F8                        → toggle ORTHO mode
ESCAPE                    → anulare comandă curentă
```

-----

## 7. LINIA DE COMANDĂ

### 7.1 Formate de input coordonate

```
Coordonate absolute Stereo70:
  587432.123,345678.456

Coordonate relative (față de ultimul punct):
  @10.5,0         (10.5m spre Est)
  @0,-15.3        (15.3m spre Sud)

Coordonate polare:
  @15.3<45        (15.3m la unghi 45°)
  @22.7<315       (22.7m la unghi 315°)
```

### 7.2 Comenzi rapide tastatură

```
P   → Polilinie (desenare limite imobil)
L   → Linie
E   → Erase / Ștergere
M   → Move / Mutare
T   → Trim / Tăiere la intersecție
X   → Extend / Extindere la intersecție
J   → Join / Unire entități
SP  → Split / Dividere entitate
Z   → Zoom
```

-----

## 8. IMPORT DATE GIS

### 8.1 Import fișiere TXT (stație totală)

**Format acceptat:**

```
Nr_pct    X            Y            Z        Cod
1001      587432.123   345678.456   245.32   LIM
1002      587445.234   345678.456   245.28   LIM
1003      587445.234   345690.123   245.41   CONST
```

**Procesare la import:**

- Puncte apar instant pe hartă (layer MASURATORI_PUNCTE)
- Snap activat automat pe toate punctele importate
- Codul punctului → culoare automată per cod
- Coordonatele exacte stocate în PostgreSQL

### 8.2 Import fișiere DXF (din AutoCAD/TopoCad)

**Layere recunoscute automat:**

```
Layer DXF "LIMITE_IMOBILE"    → poligoane imobile
Layer DXF "PUNCTE"            → puncte de măsurătoare
Layer DXF "CONSTRUCTII"       → amprente construcții
Layer DXF "DRUMURI"           → axe / limite drumuri
```

**Atribute DXF → câmpuri BD:**
Dacă DXF-ul conține atribute (XDATA), acestea se mapează automat:

- TARLA → câmpul tarla
- PARCELA → câmpul parcela
- SUPRAFATA → suprafata_act (pentru verificare)

### 8.3 Import CGXML (cărți funciare OCPI)

- Parser XML cu Nokogiri (backend Rails)
- Geometriile CF → layer CF_EXISTENTE (blocat, referință)
- Date alfanumerice → tabela carti_funciare
- Asociere automată cu imobilele din TP

### 8.4 Import planuri raster vechi

Formate acceptate: GeoTIFF, ECW, JPG, PNG, PDF scanat

**Dacă planul este georeferențiat:**
→ Se suprapune direct pe hartă (layer PLAN_VECHI)

**Dacă planul NU este georeferențiat:**
→ Se activează modulul de georeferențiere (vezi secțiunea 10)

-----

## 9. DIGITIZARE LIMITE IMOBILE

### 9.1 Fluxul de digitizare

```
1. Selectează layer LIMITE_IMOBILE (activ)
2. Comandă Polilinie (P sau click toolbar)
3. Click/snap pe primul punct (hotar imobil)
4. Continuă click/snap pe fiecare vertex
5. Suprafața calculată → afișată LIVE în status bar
6. Comparație LIVE cu suprafața din act
7. Închide poligonul (click pe primul punct)
8. Validare topologie PostGIS automată
9. Salvare în BD → notificare rezultat
```

### 9.2 Verificare suprafață în timp real

```
┌─────────────────────────────────────┐
│  Suprafață calculată:  1456.23 mp   │
│  Suprafață din act:    1450.00 mp   │
│  Diferență:            +6.23 mp     │
│  Procent:              +0.43%       │
│  Status:               🟢 OK        │  ← sub 1%
└─────────────────────────────────────┘
```

### 9.3 Semaforul de precizie suprafețe

```
🟢 Verde:   diferență < 0.1%    → OK, se poate salva
🟡 Galben:  diferență 0.1%-1%   → Avertizare, verifică
🔴 Roșu:    diferență > 1%      → Blocat, necesită corecție
```

### 9.4 Colorarea automată imobile pe hartă

**După status geometrie:**

```
🔴 Roșu   = fără geometrie    → prioritate maximă de lucru
🟡 Galben = geometrie în lucru → digitizat dar nevalidat
🟢 Verde  = validat topologic  → gata de export
🔵 Albastru = exportat în CGXML
```

**După categorie de folosință (activabil din panel layere):**

```
Arabil              = galben deschis   (#C8A84B)
Pășune              = verde deschis    (#5A8A4A)
Fânețe              = verde închis     (#3A6A3A)
Vii                 = mov              (#8A4A8A)
Livezi              = roz              (#CA7A7A)
Păduri              = verde închis     (#2A5A3A)
Ape                 = albastru         (#4A7AAA)
Drumuri             = gri              (#8A8A8A)
Curți-construcții   = portocaliu       (#CA7A3A)
Neproductiv         = gri deschis      (#AAAAAA)
```

-----

## 10. GEOREFERENȚIERE PLANURI VECHI

### 10.1 Tipuri de planuri

```
TIP 1 — Plan georeferențiat
└── Se suprapune direct pe hartă
    Stereo70 → compatibil nativ

TIP 2 — Plan negeorefențiat (frecvent)
└── Se activează modulul de georeferențiere
    Utilizatorul identifică 3-4 puncte comune
    cu Google Maps / ortofotoplan
```

### 10.2 Interfața de georeferențiere

```
┌─────────────────────────────────────────┐
│  PASUL 1 - Selectează punct pe plan     │
│  ┌──────────────┐  ┌──────────────────┐ │
│  │              │  │   Google Maps    │ │
│  │  Plan vechi  │  │                  │ │
│  │    [+]P1     │  │      [+]P1       │ │
│  │              │  │                  │ │
│  └──────────────┘  └──────────────────┘ │
│                                         │
│  Puncte definite: 1/4                   │
│  [Calculează georeferențiere]           │
└─────────────────────────────────────────┘
```

### 10.3 Calitatea georeferențierii

```
PUNCTE DEFINITE    TRANSFORMARE          PRECIZIE
───────────────────────────────────────────────────
3 puncte         → Transformare afină    medie
                   (rotație + scalare)
4+ puncte        → Transformare          ridicată
                   polinomială
                   (corecție distorsiuni)
```

**Precizie așteptată:**

- Condiții optime: ±2-3m (suficient pentru ordinea parcelelor)
- Scopul georeferențierii NU este precizia metrică, ci stabilirea
  ordinii relative și vecinătăților parcelelor

### 10.4 Markeri provizorii pe planuri vechi

Utilizatorul poate plasa markeri pe planul vechi (negeorefențiat)
pentru a indica pozițiile TP-urilor. Sistemul extrage DOAR relațiile
spațiale (cine e vecin cu cine), nu coordonatele absolute.

-----

## 11. DETECTARE AUTOMATĂ DIRECȚIE PARCELARE DIN ORTOFOTOPLAN

### 11.1 Conceptul

```
ORTOFOTOPLAN (imagine reală din satelit/avion)
        ↓
Computer Vision analizează imaginea
        ↓
Detectează pattern-uri vizuale:
├── Culturi agricole în rânduri (cel mai fiabil)
├── Urme de arat (direcție lucrări agricole)
├── Limite vizibile între parcele
├── Drumuri de acces inter-parcele
└── Vegetație liniară (garduri vii, șanțuri)
        ↓
Determină automat direcția principală
de parcelare → propune specialistului
```

### 11.2 Algoritmul de detectare

```
PASUL 1 — Preprocesare imagine (OpenCV local)
├── Conversie grayscale
├── Contrast enhancement (CLAHE)
└── Gaussian blur (reducere zgomot)

PASUL 2 — Detectare linii (Hough Transform)
└── Detectează toate liniile dominante din imagine
    → Array de linii cu unghiuri

PASUL 3 — Clustering unghiuri
└── Grupează linii similare (±10°)
    → Găsește direcția dominantă

PASUL 4 — Validare AI (dacă confidence < 70%)
└── Trimite imaginea la Claude Vision API
    → Confirmare sau corecție unghi

PASUL 5 — Rezultat
└── Unghi dominant față de Nord (grade)
    + Scor de încredere (%)
```

### 11.3 Interfața de confirmare

```
┌────────────────────────────────────────────────┐
│  DETECTARE DIRECȚIE PARCELARE                  │
│                                                │
│  [Imagine ortofoto cu linii detectate]         │
│  ↗ Direcție detectată: 87° față de Nord        │
│   Încredere: 94%                               │
│                                                │
│  DIRECȚII DETECTATE                            │
│  ● Primară:    87° (E-V)    ████████ 94%       │
│  ○ Secundară:  177° (N-S)   ███░░░░░ 42%       │
│                                                │
│  [Folosește 87°] [Ajustează manual] [Ignoră]  │
└────────────────────────────────────────────────┘
```

### 11.4 Surse combinate pentru direcție

```
SURSĂ                  GREUTATE    UTILIZARE
────────────────────────────────────────────
Ortofoto (CV)          40%         Direcție vizuală
Vecinătăți TP          30%         Confirmare juridică
Plan vechi             20%         Referință istorică
Input manual           10%         Corecție specialist
```

-----

## 12. VALIDARE TOPOLOGIE POSTGIS

### 12.1 Erorile detectate automat

```
├── Suprapuneri (overlaps)
│   └── Parcela A și B ocupă același spațiu
├── Goluri (gaps)
│   └── Spațiu neacoperit între parcele
├── Sliver polygons
│   └── Suprapuneri foarte mici din erori de digitizare
├── Self-intersections
│   └── Poligon care se intersectează cu el însuși
└── Geometrii invalide
    └── Poligoane neînchise, duplicate vertices
```

### 12.2 Funcții PostGIS utilizate

```sql
ST_IsValid(geom)         -- verifică geometrie
ST_MakeValid(geom)       -- corectează automat
ST_Overlaps(g1, g2)      -- detectează suprapuneri
ST_Touches(g1, g2)       -- verifică adiacență corectă
ST_Difference(g1, g2)    -- elimină suprapuneri
ST_Union(g1, g2)         -- unește geometrii
ST_Snap(g1, g2, tol)     -- aliniază vertices apropiate
ST_Buffer(geom, 0)       -- curăță geometrii
ST_Area(geom)            -- calculează suprafața exactă
ST_Split(geom, linie)    -- divide poligon
ST_Azimuth(p1, p2)       -- unghi între două puncte
ST_DWithin(g1, g2, dist) -- detectare vecini la distanță
```

### 12.3 Corecție automată vs semi-automată

```
CORECȚIE AUTOMATĂ (erori mici, sub prag)
├── Sliver polygons → eliminate
├── Gaps mici → atribuite parcelei vecine celei mai mari
└── Vertices la distanță < snap_tolerance → unite

CORECȚIE SEMI-AUTOMATĂ (erori mari)
├── Evidențiate vizual pe hartă (roșu pulsant)
├── Specialist decide corecția
└── PostGIS aplică corecția aleasă
```

### 12.4 Raport topologie

```
┌────────────────────────────────────────┐
│  RAPORT TOPOLOGIE                      │
│  ─────────────────────────────────     │
│  ✓ Geometrii valide: 145/150           │
│  ✗ Suprapuneri: 3                      │
│  ✗ Goluri: 2                           │
│  ⚠ Sliver polygons: 8                  │
│                                        │
│  [Corectează automat erorile mici]     │
│  [Vezi erori pe hartă]                 │
└────────────────────────────────────────┘
```

### 12.5 Regula de export

**Sistemul NU permite exportul CGXML dacă există erori de topologie nerezolvate.**
Aceasta elimină complet riscul de respingere la OCPI din cauze geometrice.

-----

## 13. DIVIZAREA AUTOMATĂ A PARCELELOR

### 13.1 Problema rezolvată

```
INPUT
├── Poligon mare (tarlaua sau parcelă mare din CGXML)
├── Lista parcele ordonate cu suprafețele din TP
├── Ordinea topologică (din modulul de vecinătăți)
└── Puncte GPS disponibile (opțional)

OUTPUT
└── N poligoane individuale
    fiecare cu suprafața din TP
    topologie corectă garantată
```

### 13.2 Moduri de divizare

```
MOD 1 — LINII PARALELE (cel mai frecvent)
└── Perpendiculare pe axa principală a tarlalei
    Util pentru: tarlale regulate

MOD 2 — LINII RADIALE
└── Din punct central
    Util pentru: parcele triunghiulare / evantai

MOD 3 — MANUAL CU CONSTRÂNGERI
└── Specialistul desenează fiecare linie
    Sistemul verifică suprafața și semnalează

MOD 4 — ANCORARE LA PUNCTE GPS
└── Liniile trec obligatoriu prin punctele măsurate
    Suprafața se ajustează la geometria reală

MOD 5 — MIXT (recomandat)
└── Auto-divizare inițială
    + Ajustare manuală unde e nevoie
    + Ancorare la puncte GPS disponibile
```

### 13.3 Algoritmul de auto-divizare

```
PASUL 1 — Determină axa principală
└── Calculează orientarea poligonului
    (minimum bounding rectangle)
    SAU folosește direcția din ortofoto (secțiunea 11)

PASUL 2 — Calculează pozițiile liniilor
└── Pentru fiecare parcelă Pi:
    poziție_linie = suma_suprafete(P1..Pi)
                    ÷ suprafata_totala
                    × lungime_axa

PASUL 3 — Generează linii de tăiere
└── Perpendiculare pe axa principală
    la pozițiile calculate

PASUL 4 — Taie poligonul
└── ST_Split (PostGIS backend)
    sau JSTS (browser pentru preview)

PASUL 5 — Calculează suprafețele rezultate
└── ST_Area per poligon → comparare cu TP

PASUL 6 — Raport diferențe
└── Unde diferența > toleranță → semnalează
```

### 13.4 Interfața de divizare

```
┌──────────────────────────────────────────────────┐
│  MOD DIVIZARE PARCELĂ — Tarlaua 15               │
│                                                  │
│  [Vizualizare poligon cu linii de divizare]      │
│                                                  │
│  SUMAR                                           │
│  Total parcelă:    45,230 mp                     │
│  Suma TP:          45,228 mp                     │
│  Diferență:           -2 mp ⚠                   │
│  Parcele definite: 18/23                         │
│                                                  │
│  TABEL PARCELE                                   │
│  Nr  │ Supraf.TP │ Supraf.calc │ Dif   │ Status  │
│  P1  │  2450 mp  │  2450.2 mp  │ +0.2  │  ✓     │
│  P2  │  1870 mp  │  1869.8 mp  │ -0.2  │  ✓     │
│  P3  │   980 mp  │   978.0 mp  │ -2.0  │  ⚠     │
│                                                  │
│  [Auto-divizare] [Ancorare puncte] [Validează]  │
└──────────────────────────────────────────────────┘
```

-----

## 14. REORDONAREA PARCELELOR — DRAG & DROP

### 14.1 Problema rezolvată

Situație frecventă: după realizarea parcelării, se descoperă că ordinea
proprietarilor este greșită (ex: proprietarul de la P7 trebuie mutat la P77).

**Soluția:** sistem drag & drop cu reconfigurare automată în cascadă și
validare automată a vecinătăților după reordonare.

### 14.2 Tipuri de operații

```
TIP 1 — SWAP (schimb poziții între 2 proprietari)
└── Doar atributele se schimbă, geometriile rămân pe loc

TIP 2 — INSERT cu decalare (cel mai frecvent)
└── Mută P7 la P77 → P8→P7, P9→P8 ... P77→P76
    Reordonare în lanț

TIP 3 — SWAP GEOMETRII
└── Schimb fizic de poligoane între doi proprietari

TIP 4 — INVERSARE INTERVAL
└── Inversează ordinea pentru un interval selectat
    P45↔P67, P46↔P66 etc.
    Util când ai numerotat în sens greșit
```

### 14.3 Interfața drag & drop

```
LISTA (drag rânduri)
┌─────────────────────────────────────┐
│ ☰  P1  │ Ionescu Ion    │ 2450 mp  │
│ ☰  P2  │ Popescu Maria  │ 1870 mp  │
│ ☰  P7  │ Marinescu A.  │ 2100 mp  │ ← DRAG
│ ☰  P76 │ Dumitru C.    │ 1200 mp  │
│ ☰  P77 │ ← DROP DEST.  │          │ ← DROP ZONE
│ ☰  P78 │ Popa N.       │ 1560 mp  │
└─────────────────────────────────────┘

HARTĂ (sincronizat)
├── P7 evidențiat (bordură groasă albastră)
├── Zona P77 pulsează (destinație)
└── Preview animat al rezultatului
```

### 14.4 Stările vizuale pe hartă în timpul drag

```
STAREA 1 — Înainte de drag
└── Toate poligoanele normale

STAREA 2 — Drag inițiat
├── Parcela sursă "ridicată" (umbră + bordură albastră)
├── Parcele afectate → colorate galben deschis
└── Zona destinație pulsează verde

STAREA 3 — Hover pe destinație
├── Preview instant al rezultatului
│   (transparență 50%, poligon în noua poziție)
└── Validare vecinătăți rulează în background

STAREA 4 — Drop confirmat
└── Animație cascadă (efect domino):
    Parcelele se recolorează în cascadă
    cu delay progresiv (0.1s per parcelă)
```

### 14.5 Algoritmul INSERT cu decalare

```
EXEMPLU: Mută P7 la poziția P77

ÎNAINTE: P1 P2 P3 P4 P5 P6 [P7] P8 P9...P76 P77 P78

PASUL 1 — Extrage P7
P1 P2 P3 P4 P5 P6 [   ] P8 P9...P76 P77 P78

PASUL 2 — Compactează (decalare -1 după P7)
P1 P2 P3 P4 P5 P6 P8→P7 P9→P8...P76→P75 P77→P76 P78→P77

PASUL 3 — Inserează la poziția 77
P1 P2 P3 P4 P5 P6 P8 P9...P75 P76 [P7_NOU] P78...

NOTA: Geometriile rămân fizic pe loc.
      Doar atributele proprietarului se mută cu poligonul.
```

-----

## 15. VALIDAREA VECINĂTĂȚILOR DUPĂ REORDONARE

### 15.1 Sursa de adevăr — vecinătățile juridice din TP

Fiecare Titlu de Proprietate conține vecinătățile juridice (Nord/Sud/Est/Vest)
pentru fiecare parcelă. Acestea sunt fixe și reprezintă adevărul juridic.

### 15.2 Algoritmul de validare în 4 pași

```
PASUL 1 — Extrage vecinătăți geometrice din PostGIS

SELECT
  i1.id, i1.proprietar_id,
  i2.id as vecin_id, i2.proprietar_id as vecin_prop,
  ST_Azimuth(ST_Centroid(i1.geom), ST_Centroid(i2.geom)) as unghi
FROM imobile i1
JOIN imobile i2 ON (
  ST_Touches(i1.geom, i2.geom)
  OR ST_DWithin(i1.geom, i2.geom, 0.05)
)
WHERE i1.proiect_id = ? AND i1.id != i2.id

PASUL 2 — Convertește unghi → direcție cardinală
└── 337.5°-22.5° → Nord
    22.5°-67.5°  → Nord-Est
    67.5°-112.5° → Est
    etc.

PASUL 3 — Compară geometric vs juridic (din TP)
└── Match exact → PERFECT ✓
    Fuzzy match  → PARȚIAL ⚠ (Levenshtein distance)
    Nepotrivire  → CONFLICT ✗

PASUL 4 — Clasificare și raport
└── Per parcelă: câte vecinătăți perfect/parțial/conflict
```

### 15.3 Fuzzy matching pentru nume proprietari

```ruby
def match_proprietar(nume_tp, proprietar_bd)
  tp = normalize(nume_tp)   # diacritice, lowercase
  bd = normalize(proprietar_bd.nume_complet)

  return :perfect if tp == bd

  # Match după CNP (cel mai sigur identificator)
  return :perfect if cnp_match?(nume_tp, proprietar_bd.cnp)

  # Distanță Levenshtein
  similaritate = 1 - levenshtein(tp, bd).to_f / [tp.length, bd.length].max
  case similaritate
  when 0.95..1.0 then :perfect
  when 0.80..0.95 then :probabil
  when 0.60..0.80 then :posibil
  else :nepotrivit
  end
end
```

### 15.4 Entități fixe (nu sunt proprietari)

Verificare specială pentru vecinătăți cu entități fixe:

```
├── Drum comunal / județean / național
├── Cale ferată
├── Râu / pârâu / canal
├── Pădure stat / UAT
├── Hotar UAT
└── Rezervație / arie protejată

VALIDARE: Dacă TP spune "Sud: Drum comunal"
→ PostGIS verifică: există geometrie de tip "drum"
  la Sud imobilului?
  DA → ✓ confirmat
  NU → ✗ eroare gravă
```

### 15.5 Raportul de validare

```
┌─────────────────────────────────────────────┐
│  VALIDARE VECINĂTĂȚI — Marinescu Alexandru  │
│  Poziție nouă: P77                          │
│                                             │
│  Dir │ TP (juridic)  │ Geometric │ Status  │
│  Nord│ Popescu Maria │ Popescu M.│   ✓     │
│  Sud │ Drum comunal  │ Drum com. │   ✓     │
│  Est │ Gheorghe V.   │ Gheorghe  │   ✓     │
│  Vest│ Pădure stat   │ Pădure    │   ✓     │
│                                             │
│  Confirmate: 4   Parțiale: 0   Conflicte: 0│
└─────────────────────────────────────────────┘
```

-----

## 16. SINCRONIZARE BIDIRECȚIONALĂ HARTĂ ↔ LISTA

### 16.1 Regula fundamentală

```
ORICE ACȚIUNE ÎN ORICARE PARTE
→ Se reflectă INSTANT în cealaltă

LISTA                    HARTĂ
─────────────────────────────────────────
Click rând P7       ↔   Zoom la P7 + evidențiere
Drag P7 → P77       ↔   Animație preview pe hartă
Hover pe rând       ↔   Highlight poligon pe hartă
Click poligon hartă ↔   Scroll la rândul din listă
Modificare atribut  ↔   Actualizare culoare poligon
```

### 16.2 Sincronizare real-time cu ActionCable (WebSocket)

```ruby
# app/models/imobil.rb
class Imobil < ApplicationRecord
  after_save :broadcast_update

  def broadcast_update
    ActionCable.server.broadcast(
      "imobile_#{proiect_id}",
      {
        action: 'update',
        imobil_id: id,
        geojson: as_geojson,
        status: status_geometrie,
        suprafata_calculata: suprafata_calculata,
        diferenta: diferenta_suprafata
      }
    )
  end
end
```

**Beneficiu:** Toți membrii echipei care lucrează pe același UAT
văd actualizările celorlalți în timp real.

-----

## 17. CONECTOR CAD ↔ WEBGIS

### 17.1 Scopul conectorului

Elimină problema de încredere a specialiștilor în precizia WebGIS
prin menținerea compatibilității complete cu fluxul de lucru CAD existent.

### 17.2 Arhitectura — Watch Folder

```
CAD (AutoCAD/TopoCad/MicroStation)
        │
        │ Salvează/Exportă DXF în folder monitorizat
        ↓
AGENT LOCAL (program mic pe calculatorul specialistului)
├── Monitorizează folderul (Watchdog)
├── Citește DXF nou/modificat
├── Validează geometrii
├── Convertește Stereo70 (dacă e nevoie)
└── Trimite la API aplicație (HTTPS + token)
        │
        ↓
APLICAȚIE WEBGIS
├── Primește geometrii
├── Afișează instant pe hartă
├── Validează topologie PostGIS
└── Notifică specialistul (WebSocket)
```

### 17.3 Sincronizare bidirecțională

```
CAD → WEBGIS
├── Geometrii măsurate/digitizate
├── Puncte stație totală
└── Modificări și corecții

WEBGIS → CAD
├── CGXML importat ca geometrie (referință)
├── Limite parcele din CF existente
├── Corecții topologie aplicate
└── Geometrii validate final
```

### 17.4 Interfața agentului local

```
┌─────────────────────────────┐
│  ● e-CAD Conector           │
│  ─────────────────────────  │
│  Folder: C:\Proiecte\UAT\   │
│  Status: ✓ Conectat         │
│  Ultim sync: 14:23:05       │
│                             │
│  Fișiere procesate: 47      │
│  Erori: 0                   │
└─────────────────────────────┘
```

-----

## 18. GENERATORUL CGXML

### 18.1 Principiul

Pe baza analizei pattern-urilor din fișierele CGXML existente (furnizate
de OCPI și validate de-a lungul timpului), sistemul generează fișiere CGXML
noi conforme cu standardele ANCPI.

### 18.2 Regula de export

```
CONDIȚII OBLIGATORII ÎNAINTE DE EXPORT
├── ✓ Toate imobilele au geometrie
├── ✓ Topologie 100% validă (zero erori PostGIS)
├── ✓ Toți proprietarii au CNP validat
├── ✓ Toate suprafețele în toleranță acceptată
└── ✓ Corespondența TP ↔ imobil confirmată

DACĂ ORICARE CONDIȚIE EȘUEAZĂ
→ Export blocat
→ Raport detaliat cu ce trebuie rezolvat
```

### 18.3 Structura CGXML generată

Generatorul reproduce fidel structura fișierelor CGXML acceptate de OCPI,
extrasă prin analiza fișierelor existente validate.

-----

## 19. PROGRESUL LUCRĂRII — DASHBOARD

### 19.1 Raportul de progres în timp real

```
┌────────────────────────────────┐
│  PROGRES UAT                   │
│  ──────────────────────────    │
│  Total imobile:    145         │
│                                │
│  🟢 Validate:     88  (61%)   │
│  🟡 În lucru:     12   (8%)   │
│  🔴 Fără geom.:   45  (31%)   │
│                                │
│  ████████████░░░░░░░  61%     │
│                                │
│  Suprafață validată:           │
│  234,450 mp / 380,000 mp       │
│                                │
│  Estimare finalizare:          │
│  ~3 zile la ritmul actual      │
└────────────────────────────────┘
```

-----

## 20. PARAMETRI CONFIGURABILI PER PROIECT

```yaml
# config/proiect.yml (exemplu structură)

topologie:
  snap_tolerance: 0.05          # metri
  sliver_threshold: 0.10        # mp — eliminare automată
  gap_threshold: 0.10           # mp — atribuire automată

suprafete:
  toleranta_verde: 0.10         # % diferență OK
  toleranta_galben: 1.00        # % diferență avertizare
  # peste 1% → roșu, blocat export

validare:
  vecini_fuzzy_min: 0.80        # similaritate minimă acceptată
  entitati_fixe:
    - "Drum comunal"
    - "Drum județean"
    - "Drum național"
    - "Cale ferată"
    - "Râu"
    - "Pârâu"
    - "Canal"
    - "Pădure stat"
    - "Hotar UAT"

detectie_directie:
  confidence_min: 0.70          # sub acest prag → Claude API
  surse_greutati:
    ortofoto: 0.40
    vecinatati_tp: 0.30
    plan_vechi: 0.20
    input_manual: 0.10
```

-----

## 21. UNDO / REDO ȘI SALVARE AUTOMATĂ

```
UNDO/REDO
├── Ctrl+Z → Anulează ultima operație GIS
├── Ctrl+Y → Reface operația anulată
└── Panel istoric → toate modificările sesiunii

SALVARE AUTOMATĂ
├── Fiecare modificare geometrie → salvată instant în BD
├── Snapshot complet la fiecare 5 minute
└── La închidere browser → starea curentă conservată
    (utilizatorul nu pierde nimic)
```

-----

## 22. CONSIDERAȚII GDPR — DATE PERSONALE ÎN GIS

```
DATE AFIȘATE PE HARTĂ (publice per proiect)
├── Număr parcelă / tarlală
├── Suprafață
├── Categorie de folosință
└── Număr CF

DATE AFIȘATE DOAR LA CLICK (autentificat)
├── Nume proprietar
└── CNP → afișat mascat: ********123

DATE NICIODATĂ AFIȘATE PE HARTĂ
├── Adresă domiciliu
├── Serie/număr CI
└── Date acte de proprietate

EXPORT CGXML
└── Conține date complete
    → Acces restricționat
    → Log acces păstrat
```

-----

## 23. REZUMAT AVANTAJE COMPETITIVE

```
FAȚĂ DE e-CAD
├── Interfață GIS integrată (nu DXF extern)
├── Validare topologie automată PostGIS
├── Sincronizare bidirecțională BD ↔ hartă
├── Detectare automată direcție parcelare (AI)
├── Reordonare drag & drop cu validare
├── Validare vecinătăți din TP vs geometrie
└── Export CGXML blocat dacă topologie invalidă

FAȚĂ DE ORICE ALT SISTEM din România
├── OCR automat pe acte de proprietate
├── Corelare automată TP ↔ CGXML
├── Ordonare topologică parcele
├── Georeferențiere planuri vechi
├── Conector CAD ↔ WebGIS
└── Modul AI specializat cadastru românesc
```

-----

*Document generat: Mai 2026*
*Versiune specificație: 1.0*
*Aplicabil pentru: Sistem Cadastru Sistematic — Înregistrare Imobile*