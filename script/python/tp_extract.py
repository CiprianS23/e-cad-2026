#!/usr/bin/env python3
"""
Extractor structurat pentru pagina verso a TP (vecinătățile).

Strategie:
  1. Citește JSON OCR (output paddleocr cu bbox per detecție)
  2. Clusterizează detecțiile pe rânduri (după y-centroid, toleranță Y_TOL)
  3. Identifică rândurile de header (conțin TARLA, PARCELA, NORD, EST, SUD, VEST)
  4. Învață pozițiile x ale coloanelor din header
  5. Pentru rândurile de date: asignează fiecare detecție la coloana cea mai apropiată după x
  6. Construiește per rând: {tarla, parcela, ha, mp, nord, est, sud, vest}

Două secțiuni posibile pe verso: A (Extravilan) și B (Intravilan).
"""
import json
import sys
import argparse
from collections import defaultdict

# Toleranță pe Y pentru a clusteriza un rând (px la 300 DPI A4)
Y_TOL = 22

# Coloanele așteptate în ordinea spațială pe TP (header de pe verso)
COL_KEYS = ['cat', 'folosinta', 'tarla', 'parcela', 'ha', 'mp', 'nord', 'est', 'sud', 'vest']

# Cuvinte cheie pentru identificarea header-ului (toate uppercase, OCR le-ar trebui captura)
HEADER_HINTS = {
    'cat':       ['CAT'],                 # NR. CAT
    'folosinta': ['FOLOSINTA', 'DE'],     # CATEGORIA DE FOLOSINTA
    'tarla':     ['TARLA', '(SOLA)'],
    'parcela':   ['PARCELA'],
    'ha':        ['Ha'],
    'mp':        ['mp'],
    'nord':      ['NORD'],
    'est':       ['EST'],
    'sud':       ['SUD'],
    'vest':      ['VEST'],
}

SECTION_HINTS = ['EXTRAVILAN', 'INTRAVILAN']


def y_center(det):
    bb = det['bbox_global_px']
    return (bb[1] + bb[3]) / 2.0

def x_center(det):
    bb = det['bbox_global_px']
    return (bb[0] + bb[2]) / 2.0

def cluster_rows(dets, y_tol=Y_TOL):
    """Grupează detecțiile pe rânduri pe baza centroidului Y."""
    dets_sorted = sorted(dets, key=y_center)
    rows = []
    current = []
    current_y = None
    for d in dets_sorted:
        y = y_center(d)
        if current_y is None or abs(y - current_y) <= y_tol:
            current.append(d)
            current_y = y if current_y is None else (current_y + y) / 2.0
        else:
            rows.append(sorted(current, key=x_center))
            current = [d]
            current_y = y
    if current:
        rows.append(sorted(current, key=x_center))
    return rows


def find_header_columns(rows):
    """Caută în rândurile de sus rândul (sau combinarea de rânduri) care
    conține anchor-urile NORD/EST/SUD/VEST + TARLA/PARCELA.

    Întoarce dict col_name → x_center; identifică și y-ul header-ului.
    """
    # Layout-ul real are header pe 3-4 rânduri (etichete suprapuse cu pozițiile labelelor pe Y).
    # Strategie: combin TOATE detecțiile cu Y în primii ~25% din pagină și caut keyword-urile.
    if not rows: return None, None

    img_y_max = max(y_center(d) for row in rows for d in row)
    header_band = []
    for row in rows:
        if all(y_center(d) < img_y_max * 0.20 for d in row):
            header_band.extend(row)
    if not header_band:
        # fallback: primele 5 rânduri
        for row in rows[:5]:
            header_band.extend(row)

    col_x = {}
    for det in header_band:
        text = det['text'].strip().upper()
        for key, hints in HEADER_HINTS.items():
            if key in col_x:  # primul match câștigă
                continue
            for hint in hints:
                if text == hint.upper() or hint.upper() in text:
                    col_x[key] = x_center(det)
                    break

    if not all(k in col_x for k in ['tarla', 'parcela', 'nord', 'est', 'sud', 'vest']):
        return None, None

    y_header_max = max(y_center(d) for d in header_band if
                       any(d['text'].strip().upper() == h.upper() for hk in HEADER_HINTS.values() for h in hk))
    return col_x, y_header_max


def assign_to_column(det, col_x, max_dist=120):
    """Întoarce numele coloanei cea mai apropiată de centroidul X al detecției, sau None."""
    xc = x_center(det)
    best, best_dist = None, max_dist
    for key, cx in col_x.items():
        d = abs(xc - cx)
        if d < best_dist:
            best, best_dist = key, d
    return best


def extract_data_rows(rows, col_x, y_header_max, y_tol=Y_TOL):
    """Pentru rânduri sub header-line, asignează detecțiile la coloane."""
    parcele = []
    for row in rows:
        if not row: continue
        yc = sum(y_center(d) for d in row) / len(row)
        if yc <= y_header_max + y_tol:
            continue  # încă în header
        record = {k: '' for k in COL_KEYS}
        confs  = {k: 0 for k in COL_KEYS}
        for det in row:
            col = assign_to_column(det, col_x)
            if not col: continue
            # Dacă mai multe detecții cad pe aceeași coloană, concatenăm
            txt = det['text'].strip()
            if record[col]:
                record[col] += ' ' + txt
            else:
                record[col] = txt
            confs[col] = max(confs[col], det['confidence'])
        record['_y'] = yc
        record['_confs'] = confs
        # Validează: trebuie să aibă măcar tarla + parcela
        if record['tarla'] or record['parcela']:
            parcele.append(record)
    return parcele


def detect_sections(rows):
    """Marchează care rânduri aparțin secțiunii Extravilan (A) sau Intravilan (B)."""
    sections = []  # listă (y_start, label)
    for row in rows:
        for det in row:
            t = det['text'].upper()
            if 'EXTRAVILAN' in t:
                sections.append((y_center(det), 'extravilan'))
            elif 'INTRAVILAN' in t:
                sections.append((y_center(det), 'intravilan'))
    return sorted(sections)


def assign_sections(parcele, sections):
    if not sections:
        for p in parcele:
            p['_section'] = 'unknown'
        return
    for p in parcele:
        sect = 'unknown'
        for y_start, label in sections:
            if p['_y'] >= y_start:
                sect = label
        p['_section'] = sect


def is_data_row(record):
    """Filtre: trebuie tarla numerică + parcela non-vidă."""
    if not record.get('tarla'): return False
    t = record['tarla'].strip()
    if not t.replace('/','').replace('-','').isdigit() and not t.isdigit():
        return False
    return True


def extract(json_path):
    d = json.load(open(json_path))
    dets = d['detections']
    rows = cluster_rows(dets)
    col_x, y_header_max = find_header_columns(rows)
    if not col_x:
        return {'error': 'header not found', 'col_x': col_x}
    sections = detect_sections(rows)
    parcele = extract_data_rows(rows, col_x, y_header_max)
    assign_sections(parcele, sections)
    parcele = [p for p in parcele if is_data_row(p)]
    return {
        'col_x':    {k: round(v, 1) for k, v in col_x.items()},
        'sections': sections,
        'parcele':  parcele,
    }


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('json_path')
    ap.add_argument('--show-confs', action='store_true')
    args = ap.parse_args()

    result = extract(args.json_path)
    if 'error' in result:
        print(json.dumps(result, indent=2, ensure_ascii=False))
        sys.exit(1)

    print(f"Coloane detectate ({len(result['col_x'])}): {result['col_x']}")
    print(f"Secțiuni: {result['sections']}")
    print(f"Parcele extrase: {len(result['parcele'])}")
    print()
    for p in result['parcele']:
        sect = p['_section']
        print(f"  [{sect:>10s}]  T{p['tarla']:<5s} P{p['parcela']:<10s} {p['mp']:>5s}mp  "
              f"N={p['nord']!r}  E={p['est']!r}  S={p['sud']!r}  V={p['vest']!r}")
