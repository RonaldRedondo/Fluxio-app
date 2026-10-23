#!/bin/bash
# ──────────────────────────────────────────────────────────────
#  Compila Fluxio, arma Fluxio.app y lo abre.
#  Uso:  ./build_and_run.sh
# ──────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Fluxio.app"

echo "▶ 1/4  Compilando Fluxio (puede tardar unos minutos la primera vez)…"
mkdir -p build
# Se compila dos veces, para Macs con chip Apple (arm64) y con chip Intel (x86_64), y se juntan en
# una sola app "universal" que funciona en cualquier Mac.
: > build/compilacion.log
for ARCH in arm64 x86_64; do
  if ! swift build -c release --arch "$ARCH" >> build/compilacion.log 2>&1; then
    grep -E "error" build/compilacion.log | head -20 || true
    echo "❌ La compilación falló. El detalle está en build/compilacion.log — pídele ayuda a Claude."
    exit 1
  fi
  PART="$(swift build -c release --arch "$ARCH" --show-bin-path)/Fluxio"
  if [ ! -f "$PART" ]; then
    echo "❌ No encuentro la app compilada ($ARCH)."
    exit 1
  fi
  cp "$PART" "build/Fluxio-$ARCH"
done
BIN="build/Fluxio-universal"
lipo -create build/Fluxio-arm64 build/Fluxio-x86_64 -output "$BIN"

echo "▶ 2/4  Preparando el icono…"
# Para cambiar el icono: reemplaza Resources/Fluxio-logo.png y borra Resources/AppIcon.icns.
# Icono de la barra de menú: reemplaza Resources/MenuBarIcon-logo.png (fondo transparente) y vuelve a compilar.
if [ ! -f Resources/AppIcon.icns ]; then
  swift Scripts/make_icon.swift Resources/Fluxio-logo.png Resources
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
# El icono de la barra de menú sale de su propio logo (líneas engordadas 8 px para que se vean a 18 pt).
if [ -f Resources/MenuBarIcon-logo.png ] && [ Resources/MenuBarIcon-logo.png -nt Resources/MenuBarIcon.png ]; then
  swift Scripts/make_menubar_icon.swift Resources/MenuBarIcon-logo.png Resources/MenuBarIcon.png 8
fi

echo "▶ 3/4  Armando Fluxio.app…"
pkill -x Fluxio 2>/dev/null || true
pkill -x Converso 2>/dev/null || true   # la versión anterior, cuando la app se llamaba Converso
rm -rf build/Converso.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Fluxio"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png "$APP/Contents/Resources/MenuBarIcon.png"
# Tipografía Inter (licencia libre OFL), incluida para funcionar sin internet.
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
# Logo de texto de la barra lateral del modo Completo (se prepara de nuevo si cambias Resources/Fluxio-wordmark.png).
if [ Resources/Fluxio-wordmark.png -nt Resources/Wordmark/Wordmark-text.png ]; then
  swift Scripts/make_wordmark.swift Resources/Fluxio-wordmark.png Resources/Wordmark
fi
cp -R Resources/Wordmark "$APP/Contents/Resources/Wordmark"
# Herramientas pequeñas incluidas (WebP y Potrace): así no hay que instalarlas.
cp -R Resources/Tools "$APP/Contents/Resources/Tools"
# Firma local (ad-hoc): no necesita cuenta de desarrollador.
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "▶ 4/4  Abriendo Fluxio…"
open "$APP"
echo "✅ Listo. Busca el icono de Fluxio en la barra de menú (arriba a la derecha)."
echo "   La app está en: $(pwd)/$APP"
