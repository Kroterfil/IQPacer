#!/bin/bash
# Actualiza IQPacer de una vez: git pull de IQPacer y de KSE y compila las cinco variantes (DELTA, ETA, WATIOS, DIST, DEMO) en bin/.
# NO exporta segmentos ni simula: usa los que ya trae el repo. Busca solo el SDK de Garmin y la clave.
#   Opcional: KSE_DIR, IQPACER_SDK, IQPACER_KEY para cambiar las rutas por defecto.
IQ="$(cd "$(dirname "$0")" && pwd)"
KSE="${KSE_DIR:-$HOME/Desktop/KSE_QTbis_BUENA_20260629}"
[ -d "$KSE/.git" ] || KSE="$HOME/Desktop/KSE_QTbis"
SDK="${IQPACER_SDK:-$(ls -d "$HOME/Library/Application Support/Garmin/ConnectIQ/Sdks/"*/ 2>/dev/null | sort | tail -1)}"
SDK="${SDK%/}"
if [ ! -x "$SDK/bin/monkeyc" ]; then   # no esta en la ruta de siempre: se busca por todo el usuario
  M="$(find "$HOME" -maxdepth 10 -name monkeyc -path "*/bin/*" 2>/dev/null | sort | tail -1)"
  [ -n "$M" ] && SDK="$(dirname "$(dirname "$M")")"
fi
KEY="${IQPACER_KEY:-$HOME/Documents/connectiq-keys/developer_key.der}"
if [ ! -f "$KEY" ]; then
  K="$(find "$HOME" -maxdepth 6 -name developer_key.der 2>/dev/null | head -1)"
  [ -n "$K" ] && KEY="$K"
fi

fallo() { echo; echo "############ ERROR ############"; echo "$1"; echo "###############################"; exit 1; }

echo "=== 1/2 Actualizando el codigo (git pull) ==="
# los cambios locales (p. ej. SegRes.mc, que se regenera) se guardan aparte para que no bloqueen el git pull
( cd "$IQ" && git stash -u -q 2>/dev/null; git pull ) || fallo "git pull de IQPacer ha fallado en $IQ"
if [ -d "$KSE/.git" ]; then ( cd "$KSE" && git stash -u -q 2>/dev/null; git pull ) || echo "(aviso: git pull de KSE ha fallado en $KSE)"; else echo "(KSE no encontrado; lo salto)"; fi

[ -x "$SDK/bin/monkeyc" ] || fallo "No encuentro monkeyc. SDK buscado: '$SDK'. Pasa IQPACER_SDK=/ruta/al/sdk"
[ -f "$KEY" ] || fallo "No encuentro la clave de firma: $KEY (pasa IQPACER_KEY=/ruta/developer_key.der)"
cd "$IQ" || fallo "No puedo entrar en $IQ"

echo "=== 2/2 Compilando las cinco variantes ==="
mkdir -p bin
for par in "monkey.jungle:IQPacer.prg" "monkey_eta.jungle:IQPacerETA.prg" "monkey_watts.jungle:IQPacerWATTS.prg" \
           "monkey_dist.jungle:IQPacerDIST.prg" "monkey_demo.jungle:IQPacerDEMO.prg"; do
  J="${par%%:*}"; O="${par##*:}"
  "$SDK/bin/monkeyc" -r -d edge1050 -f "$J" -o "bin/$O" -y "$KEY" > /tmp/iqpacer_build.txt 2>&1 || { cat /tmp/iqpacer_build.txt; fallo "monkeyc ha fallado en $J"; }
  echo "  OK  bin/$O"
done
echo
echo "LISTO. Archivos en: $IQ/bin"
ls -la bin/*.prg | awk '{print "  " $5 " bytes  " $9}'
