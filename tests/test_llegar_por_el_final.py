"""Llegar a la salida de un segmento por su FINAL (en sentido contrario, p. ej. bajando la subida): no se arma ni se suelta el aviso; por el lado bueno si:
    python3 tests/test_llegar_por_el_final.py
"""
import json, math, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sim_engine as S
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEG = os.path.join(ROOT, "resources", "segments")
FALLOS = []
def comprobar(n, c, d=""):
    print(("OK    " if c else "FALLO ") + n + (f"  [{d}]" if d and not c else ""))
    if not c: FALLOS.append(n)
idx = json.load(open(os.path.join(SEG, "index.json")))["s"]
e = idx[5]; lat0, lon0 = e[0], e[1]
ref = S.Engine(SEG); ref.load(5)
ux, uy = ref.ux, ref.uy                                        # sentido del segmento al salir
kx = S.KX_EQ * math.cos(math.radians(lat0))
def pos(s):                                                      # s metros a lo largo del sentido del segmento (negativo = antes de la salida)
    return lat0 + (s * uy) / S.KY_M, lon0 + (s * ux) / kx
def recorrer(desde, hasta, paso):
    eng = S.Engine(SEG); t = 0; armado = False; s = desde
    while (s < hasta) if paso > 0 else (s > hasta):
        la, lo = pos(s); eng.compute(t * 1000, t * 6.0, la, lo, True, t * 1000); t += 1
        armado |= eng.state == S.ST_ARMED
        s += paso
    return eng, armado
# bien: vienes de antes de la salida (s=-700) hacia ella: se arma
_, ok = recorrer(-700.0, 0.0, 6.0)
comprobar("llegando por el lado bueno se arma", ok)
# mal: vienes del lado del final (s=+700) hacia la salida (bajando la subida): nunca se arma
_, mal = recorrer(700.0, 0.0, -6.0)
comprobar("llegando por el final (sentido contrario) no se arma nunca", not mal)
print("FALLOS:", len(FALLOS)); sys.exit(1 if FALLOS else 0)
