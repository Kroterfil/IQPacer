"""Acercarse o alejarse de la salida: acercandote se arma a menos de 300 m y no hay 'alejandose'; si te acercas y das la vuelta, el motor lo nota (alejandose),
suelta el segmento y no lo vuelve a armar mientras sigas alejandote:
    python3 tests/test_acercarse_alejarse.py
"""
import json, math, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sim_engine as S
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
FALLOS = []
def comprobar(n, c, d=""):
    print(("OK    " if c else "FALLO ") + n + (f"  [{d}]" if d and not c else ""))
    if not c: FALLOS.append(n)
idx = json.load(open(os.path.join(ROOT, "resources", "segments", "index.json")))["s"]
e = idx[5]; lat0, lon0 = e[0], e[1]
kx = S.KX_EQ * math.cos(math.radians(lat0))
def pos(d): return lat0, lon0 + d / kx            # d metros al este de la salida
def paso(eng, d, t): eng.compute(t * 1000, t * 6.0, pos(d)[0], pos(d)[1], True, t * 1000)
# 1) te acercas desde 700 m hasta 150 m a 6 m/s
eng = S.Engine(os.path.join(ROOT, "resources", "segments")); t = 0; vio_aleja = False; armado_en = None
d = 700.0
while d > 150:
    paso(eng, d, t); t += 1; d -= 6.0
    vio_aleja |= eng.alejandose
    if eng.state == S.ST_ARMED and armado_en is None: armado_en = d
comprobar("acercandote nunca sale 'alejandose'", not vio_aleja)
comprobar("y se arma al entrar en los 300 m", armado_en is not None and armado_en < 310, str(armado_en))
# 2) te acercas hasta 280 m y das la vuelta
eng = S.Engine(os.path.join(ROOT, "resources", "segments")); t = 0; d = 700.0
while d > 280:
    paso(eng, d, t); t += 1; d -= 6.0
armado = eng.state == S.ST_ARMED
rearmado = False; aleja_visto = False
for _ in range(40):
    d += 6.0; paso(eng, d, t); t += 1
    aleja_visto |= eng.alejandose
    if aleja_visto and eng.state == S.ST_ARMED and d > 130: rearmado = True
comprobar("hasta dar la vuelta estaba armado", armado)
comprobar("al alejarte el motor lo nota", aleja_visto)
comprobar("suelta el segmento (ya no esta armado)", eng.state == S.ST_IDLE, str(eng.state))
comprobar("y no lo vuelve a armar mientras te alejas", not rearmado)
# 3) tras alejarte, si vuelves a acercarte, se arma otra vez
for _ in range(60):
    d -= 6.0; paso(eng, d, t); t += 1
comprobar("y si luego vuelves hacia la salida se arma de nuevo", eng.state == S.ST_ARMED and not eng.alejandose, f"{eng.state} {eng.alejandose}")
print("FALLOS:", len(FALLOS)); sys.exit(1 if FALLOS else 0)
