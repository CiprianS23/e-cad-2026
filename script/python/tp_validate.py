#!/usr/bin/env python3
"""
Cross-validează extractor-ul TP contra ground truth din MDB Sascut.

Pentru fiecare TP care:
  (a) are pagina 2 OCR JSON în ocr/
  (b) are vecinătăți populate în MDB pentru cel puțin o parcelă

Rulează tp_extract.extract() pe pagina 2, match parcele OCR↔MDB după (tarla, parcela)
și calculează similaritatea Levenshtein per direcție N/S/E/V.

Output: raport sumar (rate match) + listă cazuri eșuate pentru inspecție.
"""
import csv, subprocess, io, sys, os, json
from pathlib import Path
from collections import defaultdict, Counter

# import local
sys.path.insert(0, str(Path(__file__).parent))
from tp_extract import extract as extract_tp

OCR_DIR    = Path('/Users/cipriansavescu/e-cad-2026/tmp/sascut_tp/ocr')
PAGES_DIR  = Path('/Users/cipriansavescu/e-cad-2026/tmp/sascut_tp/pages')
MDB        = '/Users/cipriansavescu/e-cad-2026/tmp/sascut_tp/Sascut.mdb'


def levenshtein(a, b):
    """Distanță Levenshtein clasică. Returnează similaritate în [0,1]."""
    if not a and not b: return 1.0
    if not a or not b: return 0.0
    a, b = a.upper(), b.upper()
    if len(a) < len(b): a, b = b, a
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a):
        curr = [i + 1]
        for j, cb in enumerate(b):
            ins = prev[j+1] + 1
            dele = curr[j] + 1
            sub = prev[j] + (ca != cb)
            curr.append(min(ins, dele, sub))
        prev = curr
    dist = prev[-1]
    return 1.0 - dist / max(len(a), len(b))


def normalize(s):
    """Normalizează un string vecin: uppercase, strip puncte, replace abrevieri comune."""
    if not s: return ''
    s = s.upper().strip()
    # OCR ortografiază diacritice — îndepărtez
    repl = {'Ă':'A', 'Â':'A', 'Î':'I', 'Ș':'S', 'Ş':'S', 'Ț':'T', 'Ţ':'T'}
    for k,v in repl.items(): s = s.replace(k, v)
    # Punctuații redundante
    s = s.replace('.', ' ').replace(',', ' ')
    s = ' '.join(s.split())
    # Abrevieri comune: GH./GHE/GHEORGHE; C-TIN/CONSTANTIN
    repl_abbrev = [
        ('GHEORGHE', 'GH'), ('GHE', 'GH'),
        ('CONSTANTIN', 'CTIN'), ('C-TIN', 'CTIN'), ('CTIN', 'CTIN'),
        ('NICOLAE', 'N-LAE'), ('N-LAE', 'NLAE'),
        ('MIHAI', 'MIHAI'),
        ('STEFAN', 'STEFAN'), ('SEFAN', 'STEFAN'),
    ]
    for full, short in repl_abbrev:
        s = s.replace(full, short)
    return s


def load_mdb_ground_truth():
    raw_p = subprocess.run(['mdb-export', MDB, 'Parcel'], capture_output=True, text=True).stdout
    raw_t = subprocess.run(['mdb-export', MDB, 'Titluri_L18'], capture_output=True, text=True).stdout
    parcels = list(csv.DictReader(io.StringIO(raw_p)))
    titluri = list(csv.DictReader(io.StringIO(raw_t)))

    # Index per nr_titlu
    parcels_by_nr = defaultdict(list)
    for p in parcels:
        nr = p.get('parcel_dno', '').strip()
        if nr:
            parcels_by_nr[nr].append(p)

    # Map pdf_name → nr_titlu
    pdf_to_nr = {}
    for t in titluri:
        pdf = t.get('pdf_titlu', '').strip()
        nr = t.get('nr_titlu', '').strip()
        if pdf and nr:
            pdf_to_nr[pdf] = nr
    return pdf_to_nr, parcels_by_nr


def find_ocr_files_for_tp(tp_id):
    """Întoarce lista de JSON-uri OCR pentru paginile TP."""
    return sorted(OCR_DIR.glob(f"{tp_id}-*.json"))


def best_verso_page(ocr_files):
    """Pagina verso = cea cu cele mai multe detecții care includ NORD/EST/SUD/VEST în header."""
    best = None
    best_score = -1
    for f in ocr_files:
        try:
            d = json.load(open(f))
        except: continue
        score = 0
        for det in d['detections']:
            t = det['text'].upper()
            if t in ('NORD','SUD','EST','VEST','VECINATATI'):
                score += 10
            if t in ('PARCELA','TARLA','PARCEL'):
                score += 5
        if score > best_score:
            best, best_score = f, score
    return best, best_score


def match_parcel(extracted_p, mdb_p):
    """Compară tarla + parcela cu toleranță (whitespace, diacritice)."""
    t1 = (extracted_p.get('tarla') or '').strip()
    p1 = (extracted_p.get('parcela') or '').strip()
    t2 = (mdb_p.get('parcel_tno') or '').strip()
    p2 = (mdb_p.get('parcel_pno') or '').strip()
    return t1 == t2 and p1 == p2


def compare_tp(tp_id, ocr_json_path, mdb_parcels):
    """Compară un TP. Întoarce metrici per direcție + per parcelă."""
    result = extract_tp(ocr_json_path)
    if 'error' in result:
        return {'tp_id': tp_id, 'error': result['error']}

    extracted = result['parcele']
    matched_count = 0
    direction_sims = defaultdict(list)  # cheia: 'nord','est','sud','vest'

    # Match parcele OCR↔MDB
    mdb_with_vecin = [p for p in mdb_parcels if
                      p['north_b'].strip() or p['south_b'].strip() or
                      p['east_b'].strip() or p['west_b'].strip()]

    matched_records = []
    for mp in mdb_with_vecin:
        match = None
        for ep in extracted:
            if match_parcel(ep, mp):
                match = ep
                break
        if match:
            matched_count += 1
            for ocr_key, mdb_key in [('nord','north_b'), ('sud','south_b'),
                                     ('est','east_b'), ('vest','west_b')]:
                ocr_val = normalize(match[ocr_key])
                mdb_val = normalize(mp[mdb_key])
                sim = levenshtein(ocr_val, mdb_val)
                direction_sims[ocr_key].append(sim)
            matched_records.append({
                'tarla': mp['parcel_tno'], 'parcela': mp['parcel_pno'],
                'mdb': {k: mp[v] for k, v in [('N','north_b'),('S','south_b'),('E','east_b'),('V','west_b')]},
                'ocr': {k.upper(): match[v] for k, v in [('n','nord'),('s','sud'),('e','est'),('v','vest')]},
            })

    return {
        'tp_id':             tp_id,
        'mdb_parcels_total': len(mdb_parcels),
        'mdb_with_vecin':    len(mdb_with_vecin),
        'extracted':         len(extracted),
        'matched':           matched_count,
        'dir_sims':          {k: v for k, v in direction_sims.items()},
        'records':           matched_records,
    }


def main():
    pdf_to_nr, parcels_by_nr = load_mdb_ground_truth()
    print(f"MDB loaded: {len(pdf_to_nr)} titluri, {sum(len(v) for v in parcels_by_nr.values())} parcele")

    # Toate PDF-urile cu OCR done
    pages_done = set(p.stem.rsplit('-', 1)[0] for p in OCR_DIR.glob('*.json'))
    print(f"OCR-uite (cel puțin 1 pagină): {len(pages_done)}")

    # Toate TP-urile cu ground truth + OCR done
    candidates = []
    for pdf_name, nr in pdf_to_nr.items():
        tp_id = pdf_name.replace('.pdf', '')
        if tp_id not in pages_done: continue
        mp = parcels_by_nr.get(nr, [])
        with_vec = [p for p in mp if any(p[d].strip() for d in ('north_b','south_b','east_b','west_b'))]
        if with_vec:
            candidates.append((tp_id, nr, mp))
    print(f"Candidați cu ground truth + OCR done: {len(candidates)}")

    all_results = []
    for tp_id, nr, mdb_p in candidates:
        ocr_files = find_ocr_files_for_tp(tp_id)
        if not ocr_files: continue
        verso_json, score = best_verso_page(ocr_files)
        if score < 20:  # nu pare verso bun
            continue
        r = compare_tp(tp_id, verso_json, mdb_p)
        all_results.append(r)

    if not all_results:
        print("(0 TP-uri analizate — așteaptă batch OCR)")
        return

    # Aggregate
    total_matched = sum(r.get('matched', 0) for r in all_results)
    total_mdb     = sum(r.get('mdb_with_vecin', 0) for r in all_results)
    print(f"\n=== SUMAR pe {len(all_results)} TP-uri analizate ===")
    print(f"  Parcele MDB cu vecinătăți: {total_mdb}")
    print(f"  Parcele match (tarla+parcela): {total_matched} ({100*total_matched/max(total_mdb,1):.1f}%)")

    for direction in ['nord','est','sud','vest']:
        sims = []
        for r in all_results:
            sims.extend(r.get('dir_sims', {}).get(direction, []))
        if sims:
            avg = sum(sims) / len(sims)
            perfect = sum(1 for s in sims if s >= 0.95)
            high    = sum(1 for s in sims if 0.80 <= s < 0.95)
            mid     = sum(1 for s in sims if 0.50 <= s < 0.80)
            low     = sum(1 for s in sims if s < 0.50)
            print(f"  {direction.upper():>5s}: n={len(sims):>4d}  avg={avg:.3f}  "
                  f"perfect={perfect} high={high} mid={mid} low={low}")

    # Listă TP-uri cu match scăzut
    print(f"\n=== Top 5 TP-uri cu match scăzut ===")
    scored = []
    for r in all_results:
        if not r.get('matched'): continue
        avg_sim = 0; n = 0
        for sims in r.get('dir_sims', {}).values():
            avg_sim += sum(sims); n += len(sims)
        if n == 0: continue
        scored.append((avg_sim/n, r))
    scored.sort()
    for avg, r in scored[:5]:
        print(f"  {r['tp_id']}: avg_sim={avg:.2f}  matched={r['matched']}/{r['mdb_with_vecin']}")
        for rec in r['records'][:3]:
            print(f"     T{rec['tarla']}/P{rec['parcela']}")
            print(f"       MDB: {rec['mdb']}")
            print(f"       OCR: {rec['ocr']}")


if __name__ == '__main__':
    main()
