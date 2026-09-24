#!/usr/bin/env python3
"""Genera los datos de IQPacer a partir de los JSON de Karoo en segments/.

Entrada : segments/*.json  (formato del comparador: points[lat,lon,...] + rabbit_curve)
Salida  : resources/segments/index.json      inicios de todos los segmentos
          resources/segments/seg_<i>.json    liebre cada STEP m + recorrido simplificado
          resources/segments/segments.xml    declaración de recursos
          source/SegRes.mc                   índice -> recurso (generado)

Uso: python3 export_ciq.py
"""
import bisect
import glob
import json
import math
import os

STEP = 25          # m entre puntos de la liebre (constante para todos los segmentos)
SIMPLIFY_M = 2.0   # tolerancia Douglas-Peucker del recorrido
DIR_M = 30.0       # metros usados para el rumbo de salida y de llegada
KY = 110574.0      # m por grado de latitud (el Edge usa la misma constante)
KX_EQ = 111320.0   # m por grado de longitud en el ecuador

HERE = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.join(HERE, "segments")
OUT_DIR = os.path.join(HERE, "resources", "segments")
MC_OUT = os.path.join(HERE, "source", "SegRes.mc")


def interp(xs, ys, x):
    if x <= xs[0]:
        return ys[0]
    if x >= xs[-1]:
        return ys[-1]
    i = bisect.bisect_left(xs, x)
    return ys[i - 1] + (x - xs[i - 1]) * (ys[i] - ys[i - 1]) / (xs[i] - xs[i - 1])


def douglas_peucker(pts, eps):
    if len(pts) < 3:
        return list(pts)
    a, b = pts[0], pts[-1]
    dx, dy = b[0] - a[0], b[1] - a[1]
    seg = math.hypot(dx, dy) or 1e-9
    dmax, idx = 0.0, 0
    for i in range(1, len(pts) - 1):
        p = pts[i]
        d = abs(dy * p[0] - dx * p[1] + b[0] * a[1] - b[1] * a[0]) / seg
        if d > dmax:
            dmax, idx = d, i
    if dmax > eps:
        return douglas_peucker(pts[: idx + 1], eps)[:-1] + douglas_peucker(pts[idx:], eps)
    return [a, b]


def path_length(pts):
    return sum(math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]) for i in range(1, len(pts)))


def point_at(pts, dist):
    """Punto sobre la polilínea a `dist` metros del inicio."""
    acc = 0.0
    for i in range(1, len(pts)):
        l = math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1])
        if acc + l >= dist and l > 0:
            f = (dist - acc) / l
            return (pts[i - 1][0] + f * (pts[i][0] - pts[i - 1][0]),
                    pts[i - 1][1] + f * (pts[i][1] - pts[i - 1][1]))
        acc += l
    return pts[-1]


def unit(dx, dy):
    n = math.hypot(dx, dy)
    if n < 1e-6:
        raise ValueError("rumbo indefinido")
    return (round(dx / n, 5), round(dy / n, 5))


def build(src):
    with open(src, "r", encoding="utf-8") as f:
        data = json.load(f)
    points = data.get("points") or []
    curve = data.get("rabbit_curve") or []
    if len(points) < 2 or len(curve) < 2:
        raise ValueError("faltan points o rabbit_curve")

    xs = [float(p["distance_m"]) for p in curve]
    ts = [float(p["elapsed_seconds"]) for p in curve]
    for i in range(1, len(xs)):
        if xs[i] < xs[i - 1] or ts[i] < ts[i - 1]:
            raise ValueError(f"rabbit_curve no monótona en el índice {i}")
    length = xs[-1]

    # Liebre a paso fijo, en décimas de segundo. El último punto es la longitud total.
    grid = [i * STEP for i in range(int(length // STEP) + 1)]
    if grid[-1] < length - 1e-6:
        grid.append(length)
    ghost = [int(round(interp(xs, ts, d) * 10)) for d in grid]

    # Recorrido en metros locales respecto al inicio.
    lat0, lon0 = float(points[0]["lat"]), float(points[0]["lon"])
    kx = KX_EQ * math.cos(math.radians(lat0))
    local = [((float(p["lon"]) - lon0) * kx, (float(p["lat"]) - lat0) * KY) for p in points]
    simple = douglas_peucker(local, SIMPLIFY_M)
    plen = path_length(simple)

    ux, uy = point_at(simple, min(DIR_M, plen / 2))
    u = unit(ux, uy)
    ex, ey = point_at(simple, max(plen - DIR_M, plen / 2))
    last = simple[-1]
    ue = unit(last[0] - ex, last[1] - ey)

    seg = {
        "lat0": round(lat0, 7),
        "lon0": round(lon0, 7),
        "kx": round(kx, 3),
        "ky": KY,
        "len": round(length, 1),
        "step": STEP,
        "sc": round(length / plen, 5),   # recorrido simplificado -> longitud de la liebre
        "u": list(u),                    # rumbo de salida
        "ue": list(ue),                  # rumbo de llegada
        "g": ghost,                      # décimas de segundo
        "p": [v for x, y in simple for v in (int(round(x * 10)), int(round(y * 10)))],  # decímetros
    }
    info = {
        "name": data.get("name", os.path.basename(src)),
        "points": len(points),
        "ghost": len(ghost),
        "vertices": len(simple),
        "len": length,
        "T": ts[-1],
    }
    return seg, info


def main():
    sources = sorted(glob.glob(os.path.join(SRC_DIR, "*.json")))
    if not sources:
        raise SystemExit(f"No hay segmentos en {SRC_DIR}")
    os.makedirs(OUT_DIR, exist_ok=True)
    for old in glob.glob(os.path.join(OUT_DIR, "seg_*.json")):
        os.remove(old)

    index = []
    for i, src in enumerate(sources):
        seg, info = build(src)
        with open(os.path.join(OUT_DIR, f"seg_{i}.json"), "w", encoding="utf-8") as f:
            json.dump(seg, f, separators=(",", ":"))
        index.append([seg["lat0"], seg["lon0"]])
        print(f"seg_{i}: {info['name']} | {info['len']:.0f} m, {info['T']:.1f} s | "
              f"liebre {info['ghost']} pts, recorrido {info['points']} -> {info['vertices']} vértices")

    with open(os.path.join(OUT_DIR, "index.json"), "w", encoding="utf-8") as f:
        json.dump({"s": index}, f, separators=(",", ":"))

    xml = ["<resources>", '    <jsonData id="SegIndex" filename="index.json"/>']
    xml += [f'    <jsonData id="Seg{i}" filename="seg_{i}.json"/>' for i in range(len(sources))]
    xml.append("</resources>")
    with open(os.path.join(OUT_DIR, "segments.xml"), "w", encoding="utf-8") as f:
        f.write("\n".join(xml) + "\n")

    mc = [
        "// GENERADO por export_ciq.py. No editar a mano.",
        "import Toybox.Lang;",
        "",
        "function segCount() as Number {",
        f"    return {len(sources)};",
        "}",
        "",
        "function segResId(i as Number) {",
    ]
    for i in range(len(sources)):
        mc.append(f"    if (i == {i}) {{ return Rez.JsonData.Seg{i}; }}")
    mc += ["    return null;", "}", ""]
    with open(MC_OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(mc))

    print(f"OK: {len(sources)} segmento(s) -> resources/segments/ y source/SegRes.mc")


if __name__ == "__main__":
    main()
