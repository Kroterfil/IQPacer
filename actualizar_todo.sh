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
# Los TIEMPOS de los segmentos (source/SegRes.mc y las carpetas segments/ y resources/segments/) son de ESTA maquina: se exportan desde su Library y
# NO se tocan nunca. SegRes.mc esta en el repo, asi que se le dice a git que ignore sus cambios locales para que el pull no lo pise ni lo esconda.
( cd "$IQ" && git update-index --skip-worktree source/SegRes.mc 2>/dev/null; git pull ) || fallo "git pull de IQPacer ha fallado en $IQ"
if [ -d "$KSE/.git" ]; then ( cd "$KSE" && git pull ) || echo "(aviso: git pull de KSE ha fallado en $KSE; no afecta a IQPacer)"; else echo "(KSE no encontrado; lo salto)"; fi

[ -x "$SDK/bin/monkeyc" ] || fallo "No encuentro monkeyc. SDK buscado: '$SDK'. Pasa IQPACER_SDK=/ruta/al/sdk"
[ -f "$KEY" ] || fallo "No encuentro la clave de firma: $KEY (pasa IQPACER_KEY=/ruta/developer_key.der)"
cd "$IQ" || fallo "No puedo entrar en $IQ"

echo "--- Datos de segmentos que se van a usar (los de ESTA maquina) ---"
[ -f source/SegRes.mc ] || fallo "No hay source/SegRes.mc: faltan los segmentos de esta maquina."
echo "  SegRes.mc: $(ls -l source/SegRes.mc | awk '{print $6, $7, $8}')  ·  $(ls resources/segments 2>/dev/null | wc -l | tr -d ' ') ficheros en resources/segments"
if git show HEAD:source/SegRes.mc 2>/dev/null | cmp -s - source/SegRes.mc; then
  echo "  AVISO: SegRes.mc es IGUAL al del repo: no son tus tiempos de esta maquina. Si deberian serlo, exporta antes desde KSE (Enviar a IQPacer)."
else
  echo "  OK: son los segmentos exportados en esta maquina (distintos de los del repo)."
fi
echo "=== 2/2 Compilando las cinco variantes ==="
mkdir -p bin
for par in "monkey.jungle:IQPacer.prg" "monkey_eta.jungle:IQPacerETA.prg" "monkey_watts.jungle:IQPacerWATTS.prg" \
           "monkey_dist.jungle:IQPacerDIST.prg" "monkey_demo.jungle:IQPacerDEMO.prg"; do
  J="${par%%:*}"; O="${par##*:}"
  "$SDK/bin/monkeyc" -r -d edge1050 -f "$J" -o "bin/$O" -y "$KEY" > /tmp/iqpacer_build.txt 2>&1 || { cat /tmp/iqpacer_build.txt; fallo "monkeyc ha fallado en $J"; }
  echo "  OK  bin/$O"
done
echo
# comprobacion: el codigo compilado tiene que ser el ultimo (el aviso OBJETIVO del ETA esta en todos los .prg)
for O in IQPacer.prg IQPacerETA.prg IQPacerWATTS.prg IQPacerDIST.prg IQPacerDEMO.prg; do
  strings -a "bin/$O" | grep -q "OBJETIVO" || fallo "bin/$O NO tiene el codigo nuevo: no se ha actualizado. Carpeta usada: $IQ (¿es el repo de verdad, con .git?)"
done
echo "ACTUALIZADO OK: los cinco .prg llevan el codigo ultimo ($(git log --oneline -1 | cut -c1-60)) y los segmentos de esta maquina"
echo "LISTO. Archivos en: $IQ/bin  ($(date '+%d/%m/%Y %H:%M'))"
ls -la bin/*.prg | awk '{print "  " $5 " bytes  " $9}'
