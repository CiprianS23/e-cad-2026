#!/usr/bin/env bash
# Pornește serverul local și deschide browserul pe http://localhost:8000 (CLAUDE.md §11).
set -euo pipefail

cd "$(dirname "$0")"

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8000}"
URL="http://${HOST}:${PORT}"

# Deschide browserul după o scurtă pauză (best-effort, fără să blocheze).
( sleep 2
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$URL"
  elif command -v open >/dev/null 2>&1; then open "$URL"
  fi ) >/dev/null 2>&1 &

exec uvicorn backend.main:app --host "$HOST" --port "$PORT"
