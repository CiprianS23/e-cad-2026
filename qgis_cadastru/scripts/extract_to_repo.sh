#!/usr/bin/env bash
# Desprinde folderul qgis_cadastru/ intr-un repo Git nou, cu istoric curat.
# Utilizare:
#   qgis_cadastru/scripts/extract_to_repo.sh git@github.com:CiprianS23/e-cad-qgis.git
#
# Necesita: git. Creeaza un repo nou local in ../e-cad-qgis si il impinge la remote.

set -euo pipefail

REMOTE_URL="${1:-}"
if [[ -z "$REMOTE_URL" ]]; then
  echo "Eroare: lipseste URL-ul remote." >&2
  echo "Ex: $0 git@github.com:CiprianS23/e-cad-qgis.git" >&2
  exit 1
fi

# Radacina plugin-ului (folderul parinte al scriptului).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
TARGET_DIR="$(dirname "$(dirname "$PLUGIN_DIR")")/e-cad-qgis"

echo ">> Copiez $PLUGIN_DIR -> $TARGET_DIR"
rm -rf "$TARGET_DIR"
mkdir -p "$TARGET_DIR"
cp -R "$PLUGIN_DIR/." "$TARGET_DIR/"

cd "$TARGET_DIR"
git init -q
git add .
git commit -q -m "Initial: plugin QGIS cadastru in stil AutoCAD, integrat cu e-CAD"
git branch -M main
git remote add origin "$REMOTE_URL"

echo ">> Gata. Impinge cu:"
echo "   cd $TARGET_DIR && git push -u origin main"
