#!/bin/bash
# ──────────────────────────────────────────────────────────────
#  Prueba Fluxio de una vez: todas las opciones con los archivos de Ejemplos/, cancelar, cancelar una sola fila
#  y nombres raros en comprimidos. Al final dice «✅ Todo bien» o qué falló.
#  Uso (después de ./build_and_run.sh):  ./Scripts/probar.sh
#  No toca Ejemplos/ ni tus Ajustes: los resultados van a una carpeta temporal que se borra al terminar.
# ──────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.."

APP="build/Fluxio.app/Contents/MacOS/Fluxio"
[ -x "$APP" ] || { echo "❌ Primero genera la app con ./build_and_run.sh"; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
problemas=0

# «FALLO» que son correctos: el archivo de ejemplo no tiene lo que se pide (y Fluxio lo dice bien).
ESPERADOS="no tiene texto seleccionable|ya está optimizado|no lleva subtítulos|necesita su ventana"

echo "▶ 1/4  Todas las opciones con cada archivo de Ejemplos…"
for f in foto.jpg iphone.heic ejemplo.png documento.pdf notas.md informe.docx presentacion.pptx datos.csv \
         cancion.wav video.mp4 iphone.mov fotos.zip subtitulos.srt modelo.obj; do
  [ -f "Ejemplos/$f" ] || continue
  mkdir -p "$WORK/$f"
  "$APP" --selftest "Ejemplos/$f" "$WORK/$f" > "$WORK/$f.log" 2>&1
  ok=$(grep -c '^OK' "$WORK/$f.log")
  malos=$(grep '^FALLO' "$WORK/$f.log" | grep -Ev "$ESPERADOS")
  if [ -n "$malos" ]; then
    echo "   ❌ $f ($ok bien):"; echo "$malos" | sed 's/^/      /'
    problemas=$((problemas + 1))
  else
    echo "   ✓ $f: $ok opciones bien"
  fi
done

# Un video que tarde más de 2 s en convertirse (el corto termina antes de poder cancelarlo).
LARGO="Ejemplos/video-largo.mp4"; [ -f "$LARGO" ] || LARGO="Ejemplos/iphone.mov"

echo "▶ 2/4  Cancelar una conversión…"
mkdir -p "$WORK/cancelar"
if "$APP" --canceltest "$LARGO" "$WORK/cancelar" | grep -q '^OK'; then echo "   ✓ se cancela"
else echo "   ❌ no se canceló"; problemas=$((problemas + 1)); fi

echo "▶ 3/4  Cancelar una sola fila (dos videos a la vez)…"
mkdir -p "$WORK/una"
if "$APP" --cancelonetest "$WORK/una" "$LARGO" Ejemplos/video.mp4 > "$WORK/una.log" 2>&1; then echo "   ✓ el otro termina"
else echo "   ❌"; sed 's/^/      /' "$WORK/una.log"; problemas=$((problemas + 1)); fi

echo "▶ 4/4  Comprimidos con nombres que empiezan por «-»…"
mkdir -p "$WORK/raro/dentro" "$WORK/raro/salida"
touch -- "$WORK/raro/dentro/-sdel" "$WORK/raro/dentro/normal.txt"
( cd "$WORK/raro/dentro" && /usr/bin/tar -czf ../raro.tar.gz -- -sdel normal.txt )
"$APP" --cli "$WORK/raro/raro.tar.gz" a zip -o "$WORK/raro/salida" > /dev/null 2>&1
if [ "$(unzip -Z1 "$WORK/raro/salida/raro.zip" 2>/dev/null | sort | tr '\n' ' ')" = "-sdel normal.txt " ]; then
  echo "   ✓ los dos archivos dentro del ZIP"
else
  echo "   ❌ el ZIP no tiene los dos archivos"; problemas=$((problemas + 1))
fi

echo
if [ "$problemas" -eq 0 ]; then echo "✅ Todo bien."; else echo "❌ $problemas prueba(s) con problemas (arriba)."; fi
exit "$problemas"
