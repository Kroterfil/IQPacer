#!/usr/bin/env python3
"""Réplica en Python de source/PacerEngine.mc para validar la lógica sin el Edge.

Simula salidas a 1 Hz con ruido GPS sobre los segmentos reales y comprueba:
arranque único en la salida, delta final correcto, rechazo en sentido contrario.
Uso: python3 tests/sim_engine.py
"""
import glob
import json
import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

ST_IDLE, ST_ARMED, ST_RUN, ST_DONE, ST_ABORT, ST_COOL = range(6)
R_ARM, R_DISARM, GATE_HALF, MIN_SPEED, COS_MAX, MAX_JUMP = 300.0, 400.0, 25.0, 1.5, 0.5, 50.0
CONF_DIST, CONF_LAT, CONF_N, CONF_OK, OFF_LAT, OFF_SECS = 100.0, 20.0, 5, 4, 60.0, 10
KX_EQ, KY_M = 111320.0, 110574.0


class Engine:
    def __init__(self, segdir):
        self.idx = json.load(open(os.path.join(segdir, "index.json")))["s"]
        self.segdir = segdir
        self.state = ST_IDLE
        self.near = -1.0
        self.tick = 0
        self.buf = []
        self.starts = []
        self.final = None
        self.delta = 0.0
        self.eta = 0.0
        self.hold = 0

    # ---- búfer de las últimas 6 muestras respecto a una línea (salida o llegada) ----
    def buf_reset(self):
        self.buf = []

    def buf_push(self, t, v, c, x, y):
        self.buf.append((t, v, c, x, y))
        if len(self.buf) > 6:
            self.buf.pop(0)

    def gate_cross(self, ux, uy):
        """Instante estimado del cruce si la última muestra está pasada la línea y una anterior no."""
        bf = self.buf
        if len(bf) < 2:
            return None
        lt, ls, lc, lxx, lyy = bf[-1]
        if ls < 0 or ls > 60.0:
            return None
        j = -1
        for i in range(len(bf) - 2, -1, -1):
            if bf[i][1] < 0:
                j = i
                break
        if j < 0:
            return None
        at, as_, ac, ax, ay = bf[j]
        bt, bs, bc, _, _ = bf[j + 1]
        dt = (lt - at) / 1000.0
        mx, my = lxx - ax, lyy - ay
        mv = math.hypot(mx, my)
        if dt <= 0 or mv <= 0:
            return None
        sp = mv / dt
        if sp < MIN_SPEED or sp > MAX_JUMP or (mx * ux + my * uy) / mv < COS_MAX:
            return None
        f = -as_ / (bs - as_)
        if abs(ac + f * (bc - ac)) > GATE_HALF:
            return None
        return at + f * (bt - at)

    def buf_zero(self, fallback):
        """Recta por mínimos cuadrados: instante en que la coordenada vale 0."""
        n = sx = sy = sxx = sxy = 0.0
        for t, v, _, _, _ in self.buf:
            if abs(v) <= 60.0:
                tt = (t - fallback) / 1000.0
                n += 1; sx += tt; sy += v; sxx += tt * tt; sxy += tt * v
        den = n * sxx - sx * sx
        if n < 3 or den <= 0:
            return fallback
        b = (n * sxy - sx * sy) / den
        a = (sy - b * sx) / n
        if b < 0.5:
            return fallback
        return fallback + (-a / b) * 1000.0

    def load(self, i):
        s = json.load(open(os.path.join(self.segdir, f"seg_{i}.json")))
        self.lat0, self.lon0, self.kx, self.ky = s["lat0"], s["lon0"], s["kx"], s["ky"]
        self.len, self.step, self.sc = s["len"], s["step"], s["sc"]
        self.ux, self.uy = s["u"]
        self.uex, self.uey = s["ue"]
        self.g = s["g"]
        p = s["p"]
        self.n = len(p) // 2
        self.px = [p[2 * j] / 10.0 for j in range(self.n)]
        self.py = [p[2 * j + 1] / 10.0 for j in range(self.n)]
        self.cum = [0.0]
        for j in range(1, self.n):
            self.cum.append(self.cum[-1] + math.hypot(self.px[j] - self.px[j - 1], self.py[j] - self.py[j - 1]))
        self.total = self.g[-1] / 10.0
        return True

    def lx(self, lon): return (lon - self.lon0) * self.kx
    def ly(self, lat): return (lat - self.lat0) * self.ky

    def compute(self, now, odo, lat, lon, gps_ok, timer):
        if self.state == ST_IDLE:
            self.tick += 1
            if gps_ok and (self.tick % 5 == 0 or self.near < 0):
                kx = KX_EQ * math.cos(math.radians(lat))
                best, bi = -1, -1
                for i, e in enumerate(self.idx):
                    d = math.hypot((lon - e[1]) * kx, (lat - e[0]) * KY_M)
                    if bi < 0 or d < best:
                        best, bi = d, i
                self.near = best
                if bi >= 0 and best < R_ARM and self.load(bi):
                    self.state = ST_ARMED
                self.buf_reset()
        elif self.state == ST_ARMED:
            self.armed(gps_ok, lat, lon, now, odo)
        elif self.state == ST_RUN:
            self.run(gps_ok, lat, lon, now, odo, timer)
        elif self.state in (ST_DONE, ST_ABORT):
            if timer > self.hold:
                self.state = ST_COOL
        elif self.state == ST_COOL:
            if gps_ok and math.hypot(self.lx(lon), self.ly(lat)) > R_DISARM:
                self.state, self.near = ST_IDLE, -1.0

    def armed(self, gps_ok, lat, lon, now, odo):
        if not gps_ok:
            self.buf_reset()
            return
        x, y = self.lx(lon), self.ly(lat)
        self.near = math.hypot(x, y)
        if self.near > R_DISARM:
            self.state = ST_IDLE
            return
        s = x * self.ux + y * self.uy
        c = -x * self.uy + y * self.ux
        self.buf_push(now, s, c, x, y)
        tg = self.gate_cross(self.ux, self.uy)
        if tg is not None:
            self.start(tg, s, odo)

    def start(self, t0, s, odo):
        self.t0 = t0
        self.dist = max(s, 0.0)
        self.k, self.proj_prev, self.odo_prev = 0, 0.0, odo
        self.conf_n = self.conf_ok = self.off_n = 0
        self.refine_start = 3      # muestras tras la salida para afinar t0
        self.end_pending = -1
        self.state = ST_RUN
        self.starts.append(t0 / 1000.0)

    def run(self, gps_ok, lat, lon, now, odo, timer):
        d_odo = 0.0
        if odo is not None and self.odo_prev is not None:
            d_odo = odo - self.odo_prev
            if d_odo < 0 or d_odo > 60:
                d_odo = 0.0
        self.odo_prev = odo
        cand = self.dist + d_odo
        x = y = 0.0
        self.proj_lat = 1e9
        if gps_ok:
            x, y = self.lx(lon), self.ly(lat)
            self.max_adv = 25.0 + 2.0 * d_odo
            self.project(x, y)
            if self.proj_lat <= OFF_LAT:
                cand = 0.5 * (self.proj_d * self.sc) + 0.5 * (self.dist + d_odo)
                self.off_n = 0
            else:
                self.off_n += 1
        if cand > self.dist:
            self.dist = cand
        if self.dist < CONF_DIST and self.conf_n < CONF_N and gps_ok:
            self.conf_n += 1
            if self.proj_lat <= CONF_LAT:
                self.conf_ok += 1
            if self.conf_n >= CONF_N and self.conf_ok < CONF_OK:
                self.state = ST_ARMED
                self.buf_reset()
                self.starts.append("cancel")
                return
        if self.off_n >= OFF_SECS:
            self.state, self.hold = ST_ABORT, timer + 10000
            return
        # Afinar t0 con las muestras de alrededor de la salida
        if self.refine_start > 0 and gps_ok:
            self.buf_push(now, x * self.ux + y * self.uy, -x * self.uy + y * self.ux, x, y)
            self.refine_start -= 1
            if self.refine_start == 0:
                self.t0 = self.buf_zero(self.t0)
                self.buf_reset()
        self.t_you = max((now - self.t0) / 1000.0, 0.0)
        # Llegada
        if gps_ok and self.refine_start == 0:
            ex, ey = x - self.px[-1], y - self.py[-1]
            self.buf_push(now, ex * self.uex + ey * self.uey, -ex * self.uey + ey * self.uex, x, y)
            if self.end_pending < 0 and self.dist > self.len * 0.8:
                tg = self.gate_cross(self.uex, self.uey)
                if tg is not None:
                    self.end_guess = tg
                    self.end_pending = 3
            elif self.end_pending > 0:
                self.end_pending -= 1
            if self.end_pending == 0:
                self.finish((self.buf_zero(self.end_guess) - self.t0) / 1000.0, timer)
                return
        if self.dist >= self.len + 60.0:
            self.finish(self.t_you, timer)
            return
        dd = min(self.dist, self.len)
        tg = self.ghost_at(dd)
        self.delta = self.t_you - tg
        self.eta = self.total - tg
        self.d_ghost = self.ghost_dist_at(self.t_you)

    def finish(self, t_final, timer):
        self.final = t_final - self.total
        self.state, self.hold = ST_DONE, timer + 30000

    def project(self, x, y):
        lo, hi = max(self.k - 2, 0), min(self.k + 8, self.n - 2)
        found = self.project_range(x, y, lo, hi)
        if not found or self.proj_lat > 30.0:
            self.project_range(x, y, 0, self.n - 2)

    def project_range(self, x, y, lo, hi):
        best_d, best_a, best_i = 1e9, 0.0, -1
        for i in range(lo, hi + 1):
            ax, ay = self.px[i], self.py[i]
            vx, vy = self.px[i + 1] - ax, self.py[i + 1] - ay
            l2 = vx * vx + vy * vy
            t = 0.0
            if l2 > 0:
                t = min(max(((x - ax) * vx + (y - ay) * vy) / l2, 0.0), 1.0)
            d = math.hypot(ax + t * vx - x, ay + t * vy - y)
            along = self.cum[i] + t * math.sqrt(l2)
            if along < self.proj_prev - 10.0 or along > self.proj_prev + self.max_adv:
                continue
            if d < best_d:
                best_d, best_a, best_i = d, along, i
        if best_i < 0:
            return False
        if best_d < self.proj_lat:
            self.proj_lat, self.proj_d, self.k = best_d, best_a, best_i
            self.proj_prev = max(self.proj_prev, best_a)
        return True

    def ghost_at(self, d):
        gn = len(self.g)
        i = max(int(d / self.step), 0)
        if i >= gn - 1:
            return self.g[-1] / 10.0
        d0 = i * self.step
        d1 = self.len if i + 1 == gn - 1 else (i + 1) * self.step
        f = (d - d0) / (d1 - d0) if d1 > d0 else 0.0
        return (self.g[i] + f * (self.g[i + 1] - self.g[i])) / 10.0

    def ghost_dist_at(self, t):
        g, gn, tt = self.g, len(self.g), t * 10.0
        if tt <= g[0]:
            return 0.0
        if tt >= g[-1]:
            return self.len
        lo, hi = 0, gn - 1
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if g[mid] <= tt:
                lo = mid
            else:
                hi = mid
        d0 = lo * self.step
        d1 = self.len if hi == gn - 1 else hi * self.step
        span = g[hi] - g[lo]
        return d0 + ((tt - g[lo]) / span if span > 0 else 0.0) * (d1 - d0)


# ---------------- Simulación de salidas ----------------

def ride(src_json, pace=1.0, stop_at=None, stop_s=0, reverse=False, noise=3.0, seed=1, lateral=0.0):
    """Recorre el segmento original (puntos completos) con el ritmo de la liebre × pace."""
    d = json.load(open(src_json))
    pts = d["points"]
    rc = d["rabbit_curve"]
    lat0 = pts[0]["lat"]
    kx = KX_EQ * math.cos(math.radians(lat0))
    xy = [((p["lon"] - pts[0]["lon"]) * kx, (p["lat"] - lat0) * KY_M) for p in pts]
    ts = [c["elapsed_seconds"] * pace for c in rc]
    # aproximación de 500 m antes de la salida y 200 m tras la llegada, a 8 m/s
    ax, ay = xy[1][0] - xy[0][0], xy[1][1] - xy[0][1]
    n = math.hypot(ax, ay); ax, ay = ax / n, ay / n
    bx, by = xy[-1][0] - xy[-2][0], xy[-1][1] - xy[-2][1]
    n = math.hypot(bx, by); bx, by = bx / n, by / n
    track = []  # (t, x, y)
    for k in range(63):
        track.append((k * 1.0, -ax * (500 - 8 * k), -ay * (500 - 8 * k)))
    tstart = 62.5
    for (x, y), t in zip(xy, ts):
        tt = tstart + t
        if stop_at is not None and t > ts[-1] * stop_at:
            tt += stop_s
        track.append((tt, x, y))
    tend = track[-1][0]
    # velocidad final real (últimos ~50 m) para continuar tras la meta sin saltos
    j0 = max(i for i in range(len(rc)) if rc[-1]["distance_m"] - rc[i]["distance_m"] >= 50) if len(rc) > 2 else 0
    vend = (rc[-1]["distance_m"] - rc[j0]["distance_m"]) / max(ts[-1] - ts[j0], 0.1)
    for k in range(1, 26):
        track.append((tend + k, xy[-1][0] + bx * vend * k, xy[-1][1] + by * vend * k))
    if reverse:
        T = track[-1][0]
        track = [(T - t, x, y) for t, x, y in reversed(track)]
    # muestreo a 1 Hz con ruido
    rnd = random.Random(seed)
    out, j = [], 0
    odo, lastp = 0.0, None
    t = 0.0
    while t <= track[-1][0]:
        while j < len(track) - 2 and track[j + 1][0] < t:
            j += 1
        t0_, x0, y0 = track[j]
        t1_, x1, y1 = track[j + 1]
        f = 0.0 if t1_ == t0_ else min(max((t - t0_) / (t1_ - t0_), 0), 1)
        x, y = x0 + f * (x1 - x0), y0 + f * (y1 - y0)
        if lastp:
            odo += math.hypot(x - lastp[0], y - lastp[1])
        lastp = (x, y)
        nx, ny = rnd.gauss(0, noise), rnd.gauss(0, noise)
        out.append((t, odo, lat0 + (y + ny + lateral) / KY_M, pts[0]["lon"] + (x + nx) / kx))
        t += 1.0
    return out, (tstart, ts[-1] + (stop_s if stop_at is not None else 0))


def run_case(name, idx, src, **kw):
    eng = Engine(os.path.join(ROOT, "resources", "segments"))
    samples, (tstart, tseg) = ride(src, **kw)
    max_state_run = 0
    for t, odo, lat, lon in samples:
        eng.compute(int(t * 1000) + 5000, odo, lat, lon, True, int(t * 1000))
        if eng.state == ST_RUN:
            max_state_run += 1
    expected = tseg - eng.total if eng.total else None
    return eng, expected


def main():
    srcs = sorted(glob.glob(os.path.join(ROOT, "segments", "*.json")))
    cases = []
    ok = True
    for i, src in enumerate(srcs):
        nm = json.load(open(src))["name"]
        for label, kw, expect_start in [
            ("ritmo liebre", dict(pace=1.0), True),
            ("5% más lento", dict(pace=1.05), True),
            ("3% más rápido", dict(pace=0.97), True),
            ("parada 20 s a mitad", dict(pace=1.0, stop_at=0.5, stop_s=20), True),
            ("GPS ruido 6 m", dict(pace=1.0, noise=6.0, seed=7), True),
            ("sentido contrario", dict(pace=1.0, reverse=True), False),
            ("calle paralela a 45 m", dict(pace=1.0, lateral=45.0), False),
        ]:
            eng, _ = run_case(label, i, src, **kw)
            samples, (tstart, tseg) = ride(src, **kw)
            started = [s for s in eng.starts if s != "cancel"]
            exp = tseg - json.load(open(os.path.join(ROOT, "resources", "segments", f"seg_{i}.json")))["g"][-1] / 10.0
            if expect_start:
                tol = 1.0 if kw.get('noise', 3.0) <= 3.0 else 2.0
                good = eng.final is not None and abs(eng.final - exp) <= tol and len(started) == 1 \
                    and abs(started[0] - 5 - tstart) <= 1.0
                res = f"final {eng.final:+6.2f} s (esperado {exp:+6.2f}) | salida detectada t={started[0]-5:.2f} (real {tstart:.2f})" \
                    if eng.final is not None and started else f"SIN RESULTADO starts={eng.starts} state={eng.state}"
            else:
                good = eng.final is None
                res = f"sin arranque: {'OK' if good else 'FALLO'} (starts={eng.starts}, final={eng.final})"
            ok &= good
            print(f"{'OK ' if good else 'XX '} {nm[:26]:26s} | {label:22s} | {res}")
    print("\nTODO OK" if ok else "\nHAY FALLOS")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
