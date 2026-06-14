#!/usr/bin/env python3
# Genereaza un mockup al ecranului aplicatiei e-CAD Cadastru (QGIS in stil AutoCAD).
# Produce un SVG si il converteste in PNG cu cairosvg.

import cairosvg

W, H = 1600, 1000

# Paleta (consistenta cu resources/theme.qss)
BG = "#2b2b2b"
PANEL = "#333333"
PANEL2 = "#3a3a3a"
CANVAS = "#212121"
ACCENT = "#4a90d9"
STATUS = "#007acc"
CMD_BG = "#1e1e1e"
TXT = "#d6d6d6"
TXT_DIM = "#8a8a8a"
GREEN = "#6ab04c"
AMBER = "#ffaa00"
SEL = "#4a90d9"

parts = []
def add(s): parts.append(s)

add(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
    f'font-family="DejaVu Sans, Arial, sans-serif">')
add(f'<rect width="{W}" height="{H}" fill="{BG}"/>')

# ---------------------------------------------------------------- MENU BAR
add(f'<rect x="0" y="0" width="{W}" height="26" fill="{PANEL}"/>')
menus = ["Fișier", "Editare", "Vizualizare", "Cadastru", "e-CAD", "Ajutor"]
x = 14
for m in menus:
    add(f'<text x="{x}" y="17" fill="{TXT}" font-size="13">{m}</text>')
    x += len(m) * 8 + 26
add(f'<text x="{W-150}" y="17" fill="{ACCENT}" font-size="13" font-weight="bold">e-CAD Cadastru</text>')

# ---------------------------------------------------------------- TOOLBAR
add(f'<rect x="0" y="26" width="{W}" height="40" fill="#303030"/>')
add(f'<line x1="0" y1="66" x2="{W}" y2="66" stroke="#1c1c1c" stroke-width="1"/>')

def tool_btn(x, icon, active=False):
    fill = SEL if active else "#3d3d3d"
    stroke = ACCENT if active else "#4a4a4a"
    add(f'<rect x="{x}" y="32" width="28" height="28" rx="4" fill="{fill}" stroke="{stroke}"/>')
    add(icon)

tx = 12
# pan
tool_btn(tx, f'<path d="M{tx+9} 38 l5 0 l0 5 l4 0 l-6 8 l-6 -8 l4 0 z" fill="{TXT}"/>')
tx += 34
# zoom
tool_btn(tx, f'<circle cx="{tx+12}" cy="44" r="6" fill="none" stroke="{TXT}" stroke-width="2"/><line x1="{tx+16}" y1="48" x2="{tx+21}" y2="53" stroke="{TXT}" stroke-width="2"/>')
tx += 44
add(f'<line x1="{tx-6}" y1="34" x2="{tx-6}" y2="58" stroke="#4a4a4a"/>')
# Parcela noua (active)
tool_btn(tx, f'<polygon points="{tx+6},54 {tx+9},38 {tx+22},42 {tx+19},55" fill="none" stroke="#fff" stroke-width="2"/>', active=True)
tx += 34
# Masoara
tool_btn(tx, f'<line x1="{tx+6}" y1="54" x2="{tx+22}" y2="38" stroke="{AMBER}" stroke-width="2"/><circle cx="{tx+6}" cy="54" r="2" fill="{AMBER}"/><circle cx="{tx+22}" cy="38" r="2" fill="{AMBER}"/>')
tx += 44
add(f'<line x1="{tx-6}" y1="34" x2="{tx-6}" y2="58" stroke="#4a4a4a"/>')
# Import e-CAD
tool_btn(tx, f'<path d="M{tx+14} 38 l0 12 m-4 -4 l4 4 l4 -4" stroke="{GREEN}" stroke-width="2" fill="none"/><line x1="{tx+7}" y1="54" x2="{tx+21}" y2="54" stroke="{GREEN}" stroke-width="2"/>')
tx += 34
# Export cgxml
tool_btn(tx, f'<rect x="{tx+8}" y="37" width="12" height="14" fill="none" stroke="{TXT}" stroke-width="1.5"/><text x="{tx+14}" y="48" fill="{TXT}" font-size="7" text-anchor="middle">XML</text>')
tx += 44
add(f'<text x="{tx}" y="50" fill="{TXT_DIM}" font-size="12">Parcelă nouă · snapping activ</text>')

# Linia care desparte zona harta/panouri de dock-ul de comanda.
DOCK_TOP = 876

# ---------------------------------------------------------------- LEFT PANEL (Straturi)
LX, LW = 0, 260
add(f'<rect x="{LX}" y="66" width="{LW}" height="{DOCK_TOP-66}" fill="{PANEL}"/>')
add(f'<line x1="{LW}" y1="66" x2="{LW}" y2="{DOCK_TOP}" stroke="#1c1c1c"/>')
add(f'<rect x="{LX}" y="66" width="{LW}" height="26" fill="#2a2a2a"/>')
add(f'<text x="14" y="84" fill="{TXT}" font-size="13" font-weight="bold">Straturi</text>')

def layer(y, name, color, checked=True, indent=0, group=False):
    cx = 16 + indent
    if group:
        add(f'<text x="{cx}" y="{y+4}" fill="{TXT_DIM}" font-size="10">▾</text>')
        add(f'<text x="{cx+14}" y="{y+4}" fill="{AMBER}" font-size="12" font-weight="bold">{name}</text>')
        return
    box = ACCENT if checked else "#555"
    fillb = ACCENT if checked else "none"
    add(f'<rect x="{cx}" y="{y-9}" width="12" height="12" rx="2" fill="{fillb}" stroke="{box}"/>')
    if checked:
        add(f'<path d="M{cx+2} {y-3} l3 3 l5 -6" stroke="#fff" stroke-width="1.6" fill="none"/>')
    add(f'<rect x="{cx+18}" y="{y-8}" width="11" height="11" fill="{color}" stroke="#000" stroke-width="0.5"/>')
    add(f'<text x="{cx+35}" y="{y+1}" fill="{TXT}" font-size="12">{name}</text>')

ly = 112
layer(ly, "IMOBILE (cadastru)", None, group=True); ly += 24
layer(ly, "Imobile (e-CAD)", "#5a7fb0", indent=12); ly += 24
layer(ly, "Construcții", "#b05a5a", indent=12); ly += 24
layer(ly, "Părți comune", "#7a6aa0", indent=12, checked=False); ly += 30
layer(ly, "ACTE / plan parcelar", None, group=True); ly += 24
layer(ly, "Parcele", "#4c7a4c", indent=12); ly += 24
layer(ly, "Tarlale", "#9a8a3a", indent=12); ly += 24
layer(ly, "Limită UAT", "#c0c0c0", indent=12); ly += 24
layer(ly, "Sectoare cadastrale", "#666", indent=12, checked=False); ly += 30
layer(ly, "FUNDAL", None, group=True); ly += 24
layer(ly, "Ortofoto ANCPI (WMTS)", "#444", indent=12, checked=False); ly += 24

# selected layer highlight
add(f'<rect x="0" y="183" width="{LW}" height="20" fill="{SEL}" opacity="0.18"/>')

# ---------------------------------------------------------------- MAP CANVAS
MX, MW = 260, 970
MY, MH = 66, DOCK_TOP-66
add(f'<rect x="{MX}" y="{MY}" width="{MW}" height="{MH}" fill="{CANVAS}"/>')

# subtle grid
for gx in range(MX, MX+MW, 60):
    add(f'<line x1="{gx}" y1="{MY}" x2="{gx}" y2="{MY+MH}" stroke="#2a2a2a"/>')
for gy in range(MY, MY+MH, 60):
    add(f'<line x1="{MX}" y1="{gy}" x2="{MX+MW}" y2="{gy}" stroke="#2a2a2a"/>')

# tarla outline (group of parcels)
add(f'<polygon points="360,180 980,150 1060,640 420,700" fill="none" stroke="#9a8a3a" stroke-width="1.5" stroke-dasharray="6 4"/>')
add(f'<text x="990" y="150" fill="#9a8a3a" font-size="13">Tarla 23</text>')

# parcels (imobile)
parcels = [
    ("420,210 600,196 612,330 432,344", "T23 P5", "1.842 mp"),
    ("600,196 770,184 784,318 612,330", "T23 P6", "2.140 mp"),
    ("770,184 950,170 966,300 784,318", "T23 P7", "0.980 mp"),
    ("432,344 612,330 626,470 446,486", "T23 P8", "3.005 mp"),
    ("612,330 784,318 800,456 626,470", "T23 P9", "1.560 mp"),
    ("784,318 966,300 982,440 800,456", "T23 P10", "2.220 mp"),
    ("446,486 626,470 640,610 460,628", "T23 P11", "1.730 mp"),
]
for pts, num, area in parcels:
    add(f'<polygon points="{pts}" fill="#2f4258" fill-opacity="0.55" stroke="#5a7fb0" stroke-width="1.5"/>')
    # centroid approx for label
    xs = [float(p.split(",")[0]) for p in pts.split()]
    ys = [float(p.split(",")[1]) for p in pts.split()]
    cx, cy = sum(xs)/len(xs), sum(ys)/len(ys)
    add(f'<text x="{cx:.0f}" y="{cy-2:.0f}" fill="#cfe0f0" font-size="11" text-anchor="middle">{num}</text>')
    add(f'<text x="{cx:.0f}" y="{cy+11:.0f}" fill="{TXT_DIM}" font-size="9" text-anchor="middle">{area}</text>')

# selected parcel (P9) highlighted
add(f'<polygon points="612,330 784,318 800,456 626,470" fill="{SEL}" fill-opacity="0.28" stroke="{SEL}" stroke-width="2.5"/>')
for vx, vy in [(612,330),(784,318),(800,456),(626,470)]:
    add(f'<rect x="{vx-3}" y="{vy-3}" width="6" height="6" fill="{SEL}" stroke="#fff" stroke-width="0.8"/>')

# parcel being drawn (rubber band, AutoCAD-like) lower-left
draw_pts = [(470,520),(640,512),(660,648)]
poly = " ".join(f"{x},{y}" for x,y in draw_pts)
add(f'<polygon points="{poly} 540,656" fill="{ACCENT}" fill-opacity="0.12" stroke="{ACCENT}" stroke-width="2" stroke-dasharray="5 3"/>')
for vx, vy in draw_pts:
    add(f'<rect x="{vx-3}" y="{vy-3}" width="6" height="6" fill="{ACCENT}" stroke="#fff"/>')
# dynamic edge + length label (AutoCAD style)
add(f'<line x1="660" y1="648" x2="540" y2="656" stroke="{ACCENT}" stroke-width="1" stroke-dasharray="3 3"/>')
add(f'<rect x="556" y="666" width="92" height="20" rx="3" fill="#000" fill-opacity="0.75"/>')
add(f'<text x="602" y="680" fill="{AMBER}" font-size="12" text-anchor="middle">38.42 m</text>')

# crosshair cursor (full-screen, AutoCAD)
ccx, ccy = 660, 648
add(f'<line x1="{MX}" y1="{ccy}" x2="{MX+MW}" y2="{ccy}" stroke="#5a6a7a" stroke-width="0.8" stroke-opacity="0.6"/>')
add(f'<line x1="{ccx}" y1="{MY}" x2="{ccx}" y2="{MY+MH}" stroke="#5a6a7a" stroke-width="0.8" stroke-opacity="0.6"/>')
add(f'<rect x="{ccx-7}" y="{ccy-7}" width="14" height="14" fill="none" stroke="{AMBER}" stroke-width="1.2"/>')

# north arrow + scale bar
add(f'<g transform="translate(1180,120)"><polygon points="0,-18 6,8 0,2 -6,8" fill="{TXT}"/>'
    f'<text x="0" y="-22" fill="{TXT}" font-size="11" text-anchor="middle">N</text></g>')
add(f'<rect x="1090" y="860" width="60" height="5" fill="{TXT}"/>')
add(f'<rect x="1090" y="860" width="30" height="5" fill="{CANVAS}" stroke="{TXT}"/>')
add(f'<text x="1090" y="855" fill="{TXT}" font-size="10">0        50 m</text>')

# ---------------------------------------------------------------- RIGHT PANEL (Atribute)
RX, RW = 1230, 370
add(f'<rect x="{RX}" y="66" width="{RW}" height="{DOCK_TOP-66}" fill="{PANEL}"/>')
add(f'<line x1="{RX}" y1="66" x2="{RX}" y2="{DOCK_TOP}" stroke="#1c1c1c"/>')
add(f'<rect x="{RX}" y="66" width="{RW}" height="26" fill="#2a2a2a"/>')
add(f'<text x="{RX+14}" y="84" fill="{TXT}" font-size="13" font-weight="bold">Atribute imobil — T23 P9</text>')

fields = [
    ("Nr. cadastral", "51842"),
    ("Nr. CF", "51842 Berca"),
    ("Tarla / Parcelă", "23 / 9"),
    ("Suprafață (mp)", "1.560"),
    ("Categorie folosință", "Arabil (A)"),
    ("Sursă", "e-CAD · TP 1247/1994"),
]
fy = 116
for label, val in fields:
    add(f'<text x="{RX+14}" y="{fy}" fill="{TXT_DIM}" font-size="11">{label}</text>')
    add(f'<rect x="{RX+14}" y="{fy+6}" width="{RW-28}" height="22" rx="3" fill="{CMD_BG}" stroke="#4a4a4a"/>')
    add(f'<text x="{RX+22}" y="{fy+21}" fill="{TXT}" font-size="12">{val}</text>')
    fy += 46

# proprietari table
add(f'<text x="{RX+14}" y="{fy+4}" fill="{TXT}" font-size="12" font-weight="bold">Proprietari (TP)</text>')
fy += 18
add(f'<rect x="{RX+14}" y="{fy}" width="{RW-28}" height="100" fill="{CMD_BG}" stroke="#4a4a4a"/>')
add(f'<line x1="{RX+14}" y1="{fy+22}" x2="{RX+RW-14}" y2="{fy+22}" stroke="#4a4a4a"/>')
add(f'<text x="{RX+22}" y="{fy+15}" fill="{TXT_DIM}" font-size="10">Nume</text>')
add(f'<text x="{RX+220}" y="{fy+15}" fill="{TXT_DIM}" font-size="10">Cotă</text>')
rows = [("AGACHE D. DUMITRU", "1/3"), ("AGACHE D. MARIA", "1/3"), ("POPA I. VASILE", "1/3")]
ry = fy + 40
for nume, cota in rows:
    add(f'<text x="{RX+22}" y="{ry}" fill="{TXT}" font-size="11">{nume}</text>')
    add(f'<text x="{RX+220}" y="{ry}" fill="{TXT}" font-size="11">{cota}</text>')
    ry += 24
fy += 116
add(f'<rect x="{RX+14}" y="{fy}" width="120" height="26" rx="4" fill="{GREEN}" fill-opacity="0.25" stroke="{GREEN}"/>')
add(f'<text x="{RX+74}" y="{fy+17}" fill="{GREEN}" font-size="12" text-anchor="middle">Export cgxml</text>')

# ---------------------------------------------------------------- COMMAND DOCK
CY = DOCK_TOP
CH = 974 - DOCK_TOP
add(f'<rect x="0" y="{CY}" width="{W}" height="{CH}" fill="{CMD_BG}"/>')
add(f'<line x1="0" y1="{CY}" x2="{W}" y2="{CY}" stroke="#000"/>')
add(f'<text x="14" y="{CY+14}" fill="{TXT_DIM}" font-size="11" font-weight="bold">LINIE DE COMANDĂ</text>')
lines = [
    ('> deseneaza o parcela noua in tarla 23', TXT),
    ('  Interpretat ca: parcela  ·  OK', GREEN),
    ('> adu imobilele din comuna Berca', TXT),
    ('  Interpretat ca: import  ·  strat „Imobile (e-CAD)" încărcat', GREEN),
]
cyl = CY + 30
mono = 'font-family="DejaVu Sans Mono, monospace"'
for txt, col in lines:
    add(f'<text x="14" y="{cyl}" fill="{col}" font-size="12" {mono}>{txt}</text>')
    cyl += 16
# input line with cursor
add(f'<text x="14" y="{CY+CH-9}" fill="{ACCENT}" font-size="13" {mono}>Comandă: '
    f'<tspan fill="{TXT}">cât e suprafața parcelei selectate?</tspan>'
    f'<tspan fill="{TXT}" font-weight="bold">▮</tspan></text>')

# ---------------------------------------------------------------- STATUS BAR
SY = 974
add(f'<rect x="0" y="{SY}" width="{W}" height="{H-SY}" fill="{STATUS}"/>')
add(f'<text x="14" y="{SY+17}" fill="#fff" font-size="12">X: 612.430,18   Y: 392.187,55</text>')
add(f'<text x="320" y="{SY+17}" fill="#fff" font-size="12">Scară 1:1.000</text>')
add(f'<text x="470" y="{SY+17}" fill="#fff" font-size="12">Snapping: vârf, segment</text>')
add(f'<text x="{W-360}" y="{SY+17}" fill="#fff" font-size="12">EPSG:3844 — Stereo 70</text>')
add(f'<text x="{W-120}" y="{SY+17}" fill="#fff" font-size="12">● e-CAD conectat</text>')

add('</svg>')

svg = "\n".join(parts)
with open("/tmp/mockup.svg", "w", encoding="utf-8") as f:
    f.write(svg)
cairosvg.svg2png(bytestring=svg.encode("utf-8"),
                 write_to="/home/user/e-cad-2026/qgis_cadastru/mockup.png",
                 output_width=W, output_height=H)
print("PNG generat:", "qgis_cadastru/mockup.png")
