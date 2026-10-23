#!/bin/bash
# ──────────────────────────────────────────────────────────────
#  Crea Fluxio.dmg: un disco que se abre con una ventana para arrastrar Fluxio a Aplicaciones
#  (fondo con el degradado de Fluxio, el icono a la izquierda y la carpeta Aplicaciones a la derecha).
#  Uso (después de ./build_and_run.sh):  ./Scripts/make_dmg.sh [carpeta-de-salida]
#  La primera vez, macOS puede pedir permiso para que Terminal controle Finder: pulsa «Permitir»
#  (Finder es quien guarda la posición de los iconos y el fondo de la ventana).
# ──────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Fluxio.app"
OUT="${1:-build/release}"
VOLUME="Fluxio"
[ -d "$APP" ] || { echo "❌ Primero genera la app con ./build_and_run.sh"; exit 1; }
mkdir -p "$OUT"

WORK="$(mktemp -d)"
MOUNT="/Volumes/$VOLUME"
cleanup() {
  hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "▶ 1/4  Dibujando el fondo…"
swift Scripts/make_dmg_background.swift "$WORK/fondo" >/dev/null
mkdir -p "$WORK/disco/.background"
# Un solo TIFF con las dos resoluciones: nítido en pantallas Retina y normales.
tiffutil -cathidpicheck "$WORK/fondo/fondo.png" "$WORK/fondo/fondo@2x.png" -out "$WORK/disco/.background/fondo.tiff" >/dev/null 2>&1

echo "▶ 2/4  Preparando el disco…"
ditto "$APP" "$WORK/disco/Fluxio.app"
ln -s /Applications "$WORK/disco/Aplicaciones"
hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true
hdiutil create -quiet -srcfolder "$WORK/disco" -volname "$VOLUME" -fs HFS+ -format UDRW -ov "$WORK/temporal.dmg"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$WORK/temporal.dmg"

echo "▶ 3/4  Colocando los iconos…"
# Ventana de 660 × 400 puntos; los centros de los iconos coinciden con el fondo (make_dmg_background.swift).
osascript <<EOF
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:fondo.tiff"
    set position of item "Fluxio.app" of container window to {170, 160}
    set position of item "Aplicaciones" of container window to {490, 160}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
# El icono del disco, al final (si se pone antes, Finder lo quita al guardar la ventana).
cp Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT"
sync
hdiutil detach "$MOUNT" -quiet

echo "▶ 4/4  Comprimiendo…"
rm -f "$OUT/Fluxio.dmg"
hdiutil convert -quiet "$WORK/temporal.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT/Fluxio.dmg"
echo "✅ Listo: $OUT/Fluxio.dmg ($(du -h "$OUT/Fluxio.dmg" | cut -f1))"
