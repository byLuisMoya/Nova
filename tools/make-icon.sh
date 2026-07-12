#!/bin/bash
# Regenera el icono de Nova: renderiza el PNG maestro (1024) con make-icon.swift
# y construye Resources/AppIcon.icns con todos los tamaños (sips + iconutil).
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="$DIR/Resources/AppIcon-1024.png"
ICNS="$DIR/Resources/AppIcon.icns"
STYLE="${1:-outrun}"   # estilo del icono (solar · neon · outrun · holo)

echo "==> Renderizando PNG maestro (estilo: $STYLE)..."
swift "$DIR/tools/make-icon.swift" "$MASTER" "$STYLE"

echo "==> Construyendo iconset..."
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
gen() { sips -z "$2" "$2" "$MASTER" --out "$SET/$1" >/dev/null; }
gen icon_16x16.png 16;    gen icon_16x16@2x.png 32
gen icon_32x32.png 32;    gen icon_32x32@2x.png 64
gen icon_128x128.png 128; gen icon_128x128@2x.png 256
gen icon_256x256.png 256; gen icon_256x256@2x.png 512
gen icon_512x512.png 512
cp "$MASTER" "$SET/icon_512x512@2x.png"

iconutil -c icns "$SET" -o "$ICNS"
echo "✅ $ICNS"
