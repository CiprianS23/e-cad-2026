@echo off
REM Pornește serverul local si deschide browserul pe http://localhost:8000 (CLAUDE.md §11).
cd /d "%~dp0"

set HOST=127.0.0.1
set PORT=8000

start "" "http://%HOST%:%PORT%"
uvicorn backend.main:app --host %HOST% --port %PORT%
