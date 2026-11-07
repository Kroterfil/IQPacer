"""Bajas por el final del segmento, pasas la salida, das la vuelta y entras de verdad: SI debe detectarse (la regla de 'llegar por el final' no puede taparlo):
    python3 tests/test_vuelta_en_la_salida.py
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
ref = S.Engine(SEG); ref.load(5); ux, uy = ref.ux, ref.uy
kx = S.KX_EQ * math.cos(math.radians(lat0))
pos = lambda s: (lat0 + (s * uy) / S.KY_M, lon0 + (s * ux) / kx)
def ruta(tramos, v=6.0):
    eng = S.Engine(SEG); t = 0; armado_en = []; cur = None
    for (a, b) in tramos:
        s = a; paso = v if b > a else -v
        while (s < b) if paso > 0 else (s > b):
            la, lo = pos(s); eng.compute(t * 1000, t * v, la, lo, True, t * 1000); t += 1
            if eng.state == S.ST_RUN: return eng, True
            s += paso
    return eng, eng.state == S.ST_RUN
# bajando desde +400 hasta -80 (pasas la salida), vuelta, y entras: de -80 hasta +100
for pausa in (0, 3, 8, 15):
    tramos = [(400.0, -80.0), (-80.0, -80.0 - 0.0)] if False else [(400.0, -80.0)] + [(-80.0, -80.0)] * 0
    # parado 'pausa' s en el giro: se simula con muestras en el mismo punto
    eng = S.Engine(SEG); t = 0; ok = False
    def paso(s):
        global t
        la, lo = pos(s); eng.compute(t * 1000, t * 6.0, la, lo, True, t * 1000); t += 1
    s = 400.0
    while s > -80: paso(s); s -= 6.0
    for _ in range(pausa): paso(-80.0)
    s = -80.0
    while s < 100:
        paso(s); s += 6.0
        if eng.state == S.ST_RUN: ok = True; break
    comprobar(f"bajar, pasar la salida, girar (parado {pausa} s) y entrar: se detecta", ok, str(eng.state))
print("FALLOS:", len(FALLOS)); sys.exit(1 if FALLOS else 0)
