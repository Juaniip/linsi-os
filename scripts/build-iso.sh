#!/bin/bash
# scripts/build-iso.sh — Build de la ISO dentro de Docker o nativo en Linux
# Uso: ./scripts/build-iso.sh [--clean]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$ROOT_DIR/output"

echo "╔══════════════════════════════════════╗"
echo "║          LINSI OS — ISO Build        ║"
echo "╚══════════════════════════════════════╝"

# Verificar que corremos en Linux
if [[ "$(uname -s)" != "Linux" ]]; then
    echo "ERROR: Este script debe correr en Linux (usá Docker desde Windows)."
    exit 1
fi

# Verificar live-build instalado
if ! command -v lb &>/dev/null; then
    echo "ERROR: live-build no está instalado."
    echo "  sudo apt install live-build"
    exit 1
fi

# Limpiar si se pide
if [[ "${1:-}" == "--clean" ]]; then
    echo "[*] Limpiando build anterior..."
    sudo lb clean --purge
fi

mkdir -p "$OUTPUT_DIR"
cd "$ROOT_DIR"

echo "[*] Configurando live-build..."
sudo lb config

echo "[*] Iniciando build (puede tardar 20-40 min)..."
sudo lb build 2>&1 | tee "$OUTPUT_DIR/build.log"

# Mover ISO al output
ISO_FILE=$(find . -maxdepth 1 -name "*.iso" | head -1)
if [[ -n "$ISO_FILE" ]]; then
    VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo "dev")
    DEST="$OUTPUT_DIR/linsi-os-${VERSION}.iso"
    mv "$ISO_FILE" "$DEST"
    echo ""
    echo "✅ ISO generada: $DEST"
    sha256sum "$DEST" | tee "$DEST.sha256"
else
    echo "ERROR: No se encontró la ISO generada."
    exit 1
fi
