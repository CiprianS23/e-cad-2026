#!/usr/bin/env python3
"""
Batch OCR pe TP-uri scanate (Sascut).

Workflow per PDF:
  1. pdftoppm → PNG-uri 300 DPI per pagină (cache, skip if existent)
  2. PaddleOCR pe fiecare PNG → JSON detecții (skip if existent)

Output structure:
  <out_dir>/pages/T_<no>_p<N>.png
  <out_dir>/ocr/T_<no>_p<N>.json
  <out_dir>/batch.log

Paralelizare: multiprocessing.Pool cu init per worker (model încărcat o dată).
"""
import argparse
import json
import os
import subprocess
import sys
import time
import multiprocessing as mp
from pathlib import Path

from PIL import Image
import numpy as np

Image.MAX_IMAGE_PIXELS = 1_000_000_000

_OCR = None  # per-worker singleton


def init_worker():
    global _OCR
    from paddleocr import PaddleOCR
    _OCR = PaddleOCR(
        use_doc_orientation_classify=False,
        use_doc_unwarping=False,
        use_textline_orientation=False,
        text_detection_model_name="PP-OCRv5_mobile_det",
        text_recognition_model_name="en_PP-OCRv5_mobile_rec",
    )
    print(f"  [worker {os.getpid()}] PaddleOCR ready", flush=True)


def ocr_image(png_path):
    img = Image.open(png_path)
    if img.mode != "RGB":
        img = img.convert("RGB")
    arr = np.array(img)
    results = _OCR.predict(arr)
    detections = []
    for res in results or []:
        polys  = res.get("rec_polys", []) if hasattr(res, "get") else getattr(res, "rec_polys", [])
        texts  = res.get("rec_texts", []) if hasattr(res, "get") else getattr(res, "rec_texts", [])
        scores = res.get("rec_scores", []) if hasattr(res, "get") else getattr(res, "rec_scores", [])
        for poly, text, score in zip(polys, texts, scores):
            poly_np = np.array(poly).reshape(-1, 2)
            xs = poly_np[:, 0]; ys = poly_np[:, 1]
            detections.append({
                "text":       str(text),
                "confidence": float(score),
                "bbox_px":    [float(xs.min()), float(ys.min()), float(xs.max()), float(ys.max())],
                "poly_px":    [[float(x), float(y)] for x, y in poly_np.tolist()],
            })
    return {
        "image": str(png_path),
        "width": img.size[0],
        "height": img.size[1],
        "detections": detections,
    }


def process_pdf(args):
    pdf_path, out_root = args
    pdf_path = Path(pdf_path)
    out_root = Path(out_root)
    pages_dir = out_root / "pages"
    ocr_dir   = out_root / "ocr"
    pages_dir.mkdir(parents=True, exist_ok=True)
    ocr_dir.mkdir(parents=True, exist_ok=True)

    tp_id = pdf_path.stem  # ex. T-128301 sau T_503201
    t0 = time.time()

    # 1) pdftoppm → PNG-uri (idempotent)
    existing_pages = sorted(pages_dir.glob(f"{tp_id}-*.png"))
    if not existing_pages:
        prefix = pages_dir / tp_id
        try:
            subprocess.run(
                ["pdftoppm", "-r", "300", "-png", str(pdf_path), str(prefix)],
                check=True, capture_output=True, timeout=120
            )
        except subprocess.CalledProcessError as e:
            return {"pdf": str(pdf_path), "error": f"pdftoppm failed: {e.stderr.decode()[:200]}"}
        except subprocess.TimeoutExpired:
            return {"pdf": str(pdf_path), "error": "pdftoppm timeout"}
        existing_pages = sorted(pages_dir.glob(f"{tp_id}-*.png"))

    if not existing_pages:
        return {"pdf": str(pdf_path), "error": "no pages produced"}

    # 2) OCR per pagină (idempotent — skip if JSON există)
    page_results = []
    pages_processed = 0
    for png in existing_pages:
        json_path = ocr_dir / f"{png.stem}.json"
        if json_path.exists():
            page_results.append({"page": png.name, "cached": True})
            continue
        try:
            res = ocr_image(png)
            tmp = json_path.with_suffix(".json.tmp")
            with open(tmp, "w") as f:
                json.dump(res, f, ensure_ascii=False)
            tmp.rename(json_path)
            page_results.append({
                "page": png.name,
                "detections": len(res["detections"]),
            })
            pages_processed += 1
        except Exception as e:
            page_results.append({"page": png.name, "error": str(e)[:200]})

    return {
        "pdf":             pdf_path.name,
        "tp_id":           tp_id,
        "pages_total":     len(existing_pages),
        "pages_processed": pages_processed,
        "elapsed_seconds": round(time.time() - t0, 1),
        "pages":           page_results,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pdf-dir",  required=True, help="Folder cu PDF-uri")
    ap.add_argument("--out-dir",  required=True, help="Folder output (creează pages/ și ocr/)")
    ap.add_argument("--workers",  type=int, default=4)
    ap.add_argument("--limit",    type=int, default=0, help="Procesează maxim N (0=tot)")
    ap.add_argument("--log",      default="-", help="Fișier log progres (- = stdout)")
    args = ap.parse_args()

    pdfs = sorted(Path(args.pdf_dir).glob("T*.pdf"))
    if args.limit:
        pdfs = pdfs[:args.limit]
    print(f"[BATCH] {len(pdfs)} PDF-uri de procesat cu {args.workers} workeri", flush=True)

    log_f = sys.stdout if args.log == "-" else open(args.log, "a", buffering=1)

    t0 = time.time()
    tasks = [(str(p), args.out_dir) for p in pdfs]

    completed = 0
    errors = 0
    total_dets = 0
    with mp.Pool(processes=args.workers, initializer=init_worker) as pool:
        for r in pool.imap_unordered(process_pdf, tasks):
            completed += 1
            if "error" in r:
                errors += 1
                log_f.write(f"[ERR  {completed:>4d}/{len(pdfs)}] {r['pdf']}: {r['error']}\n")
            else:
                dets = sum(p.get("detections", 0) for p in r["pages"])
                total_dets += dets
                log_f.write(
                    f"[OK   {completed:>4d}/{len(pdfs)}] {r['pdf']:<25s}  "
                    f"pages={r['pages_total']}  new={r['pages_processed']}  "
                    f"dets={dets:>4d}  {r['elapsed_seconds']:>5.1f}s\n"
                )
            if completed % 10 == 0:
                elapsed = time.time() - t0
                rate = completed / elapsed
                eta = (len(pdfs) - completed) / rate if rate > 0 else 0
                log_f.write(f"[PROG] {completed}/{len(pdfs)} ({100*completed/len(pdfs):.1f}%) "
                            f"elapsed={elapsed/60:.1f}min  ETA={eta/60:.1f}min  errors={errors}\n")

    print(f"\n[DONE] {completed}/{len(pdfs)} în {(time.time()-t0)/60:.1f} min  "
          f"errors={errors}  total_detections={total_dets}", flush=True)


if __name__ == "__main__":
    main()
