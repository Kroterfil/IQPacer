import Toybox.Activity;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Position;
import Toybox.System;
import Toybox.WatchUi;

// Estados del motor
const ST_IDLE = 0;     // lejos de cualquier salida
const ST_ARMED = 1;    // cerca de una salida, esperando el cruce
const ST_RUN = 2;      // dentro del segmento
const ST_DONE = 3;     // terminado, resultado congelado
const ST_ABORT = 4;    // fuera de ruta
const ST_COOL = 5;     // espera a alejarse antes de rearmar

// Umbrales (ajustables tras pruebas reales)
const R_ARM = 300.0;       // m: radio para armar
const R_DISARM = 400.0;    // m: radio para desarmar / salir de cooldown
const END_NEAR = 120.0;     // m: la línea de meta solo vale a menos de esto del final (curvas que pasan junto a la meta)
const SWITCH_MARGIN = 10.0; // m: otra salida debe estar así de más cerca para cambiar de segmento
const GATE_HALF = 25.0;    // m: semianchura de la línea de salida y llegada
const MIN_SPEED = 1.5;     // m/s mínimos para aceptar el cruce
const COS_MAX = 0.5;       // cos(60°): rumbo máximo respecto a la línea
const MAX_JUMP = 50.0;     // m/s: salto GPS descartado
const CONF_DIST = 100.0;   // m de confirmación tras la salida
const CONF_LAT = 20.0;     // m de error lateral admitido en confirmación
const CONF_N = 5;          // muestras de confirmación
const CONF_OK = 4;         // muestras buenas exigidas
const OFF_LAT = 60.0;      // m de error lateral para considerar fuera de ruta
const OFF_SECS = 10;       // s seguidos fuera de ruta para abortar
const BUF_N = 6;           // muestras usadas alrededor de cada línea
const REFINE_N = 3;        // muestras tras la línea antes de afinar el instante
const HOLD_DONE_MS = 30000;
const HOLD_ABORT_MS = 10000;
const KX_EQ = 111320.0;
const KY_M = 110574.0;

// Réplica exacta en Python: tests/sim_engine.py
class PacerEngine {
    // Estado público para la vista
    public var state = ST_IDLE;
    public var nearDist = -1.0;   // m a la salida más cercana (IDLE) o a la salida armada (ARMED)
    public var delta = 0.0;       // s: + detrás de la liebre, - delante
    public var eta = 0.0;         // s hasta meta a ritmo de liebre desde tu posición
    public var tYou = 0.0;        // s desde la salida
    public var dist = 0.0;        // m recorridos en el segmento
    public var dGhost = 0.0;      // m de la liebre en tu tiempo
    public var remain = 0.0;      // m que faltan
    public var len = 0.0;         // m del segmento
    public var finalDelta = 0.0;  // s al terminar

    // Índice de salidas
    private var _idx = null;
    private var _tick = 0;

    // Segmento cargado
    private var _lat0 = 0.0d;
    private var _lon0 = 0.0d;
    private var _kx = 0.0;
    private var _ky = KY_M;
    private var _step = 25.0;
    private var _sc = 1.0;
    private var _ux = 0.0;
    private var _uy = 1.0;
    private var _uex = 0.0;
    private var _uey = 1.0;
    private var _g = null;       // liebre, décimas de segundo
    private var _px = null;      // recorrido, m
    private var _py = null;
    private var _cum = null;     // longitud acumulada del recorrido
    private var _n = 0;
    private var _total = 0.0;    // s totales de la liebre

    // Búfer de las últimas muestras respecto a una línea
    private var _bt = null;
    private var _bs = null;
    private var _bc = null;
    private var _bx = null;
    private var _by = null;
    private var _bn = 0;

    // Seguimiento
    private var _t0 = 0.0;
    private var _k = 0;
    private var _projPrev = 0.0;
    private var _projD = 0.0;
    private var _projLat = 0.0;
    private var _maxAdv = 25.0;
    private var _odoPrev = null;
    private var _confN = 0;
    private var _confOk = 0;
    private var _offN = 0;
    private var _refine = 0;
    private var _endPending = -1;
    private var _endGuess = 0.0;
    private var _holdUntil = 0;

    function initialize() {
        _bt = new [BUF_N];
        _bs = new [BUF_N];
        _bc = new [BUF_N];
        _bx = new [BUF_N];
        _by = new [BUF_N];
        var data = WatchUi.loadResource(Rez.JsonData.SegIndex);
        _idx = data["s"];
    }

    function compute(info as Activity.Info) as Void {
        var now = info.elapsedTime;
        var odo = info.elapsedDistance;
        var loc = info.currentLocation;
        var q = info.currentLocationAccuracy;
        var gpsOk = (loc != null) && (q == null || q >= Position.QUALITY_POOR);
        var lat = 0.0d;
        var lon = 0.0d;
        if (gpsOk) {
            var deg = loc.toDegrees();
            lat = deg[0].toDouble();
            lon = deg[1].toDouble();
        }
        if (now == null) {
            now = 0;
        }

        if (state == ST_IDLE) {
            _tick += 1;
            if (gpsOk && (_tick % 5 == 0 || nearDist < 0)) {
                scanIndex(lat, lon);
            }
        } else if (state == ST_ARMED) {
            stepArmed(gpsOk, lat, lon, now, odo);
        } else if (state == ST_RUN) {
            stepRun(gpsOk, lat, lon, now, odo);
        } else if (state == ST_DONE || state == ST_ABORT) {
            if (System.getTimer() > _holdUntil) {
                state = ST_COOL;
            }
        } else if (state == ST_COOL) {
            if (gpsOk) {
                var x = localX(lon);
                var y = localY(lat);
                if (Math.sqrt(x * x + y * y) > R_DISARM) {
                    unload();
                    state = ST_IDLE;
                    nearDist = -1.0;
                }
            }
        }
    }

    // ---------- IDLE ----------

    private function scanIndex(lat, lon) as Void {
        var kx = KX_EQ * Math.cos(Math.toRadians(lat));
        var best = -1.0;
        var bestI = -1;
        for (var i = 0; i < _idx.size(); i++) {
            var e = _idx[i];
            var dx = (lon - e[1].toDouble()) * kx;
            var dy = (lat - e[0].toDouble()) * KY_M;
            var d = Math.sqrt(dx * dx + dy * dy);
            if (bestI < 0 || d < best) {
                best = d;
                bestI = i;
            }
        }
        nearDist = best;
        if (bestI >= 0 && best < R_ARM) {
            if (load(bestI)) {
                state = ST_ARMED;
                bufReset();
            }
        }
    }

    // ---------- ARMED ----------

    private function switchIfCloser(lat, lon) as Boolean {
        var kx = KX_EQ * Math.cos(Math.toRadians(lat));
        var best = nearDist - SWITCH_MARGIN;
        var bestI = -1;
        for (var i = 0; i < _idx.size(); i++) {
            var e = _idx[i];
            var dx = (lon - e[1].toDouble()) * kx;
            var dy = (lat - e[0].toDouble()) * KY_M;
            var d = Math.sqrt(dx * dx + dy * dy);
            if (d < best) {
                best = d;
                bestI = i;
            }
        }
        if (bestI >= 0 && load(bestI)) {
            nearDist = best;
            bufReset();
            return true;
        }
        return false;
    }

    private function stepArmed(gpsOk, lat, lon, now, odo) as Void {
        if (!gpsOk) {
            bufReset();
            return;
        }
        var x = localX(lon);
        var y = localY(lat);
        nearDist = Math.sqrt(x * x + y * y);
        if (nearDist > R_DISARM) {
            unload();
            state = ST_IDLE;
            return;
        }
        // Otra salida claramente más cercana (salidas vecinas): cambiar de segmento
        _tick += 1;
        if (_tick % 2 == 0 && switchIfCloser(lat, lon)) {
            return;
        }
        var s = x * _ux + y * _uy;          // a lo largo del rumbo de salida
        var c = -x * _uy + y * _ux;         // lateral
        bufPush(now, s, c, x, y);
        var tg = gateCross(_ux, _uy);
        if (tg != null) {
            startRun(tg, s, odo);
        }
    }

    private function startRun(t0, s, odo) as Void {
        _t0 = t0;
        dist = (s > 0) ? s : 0.0;
        _k = 0;
        _projPrev = 0.0;
        _odoPrev = odo;
        _confN = 0;
        _confOk = 0;
        _offN = 0;
        _refine = REFINE_N;
        _endPending = -1;
        delta = 0.0;
        state = ST_RUN;
    }

    // ---------- RUN ----------

    private function stepRun(gpsOk, lat, lon, now, odo) as Void {
        var dOdo = 0.0;
        if (odo != null && _odoPrev != null) {
            dOdo = odo - _odoPrev;
            if (dOdo < 0 || dOdo > 60) {
                dOdo = 0.0;
            }
        }
        _odoPrev = odo;

        var cand = dist + dOdo;
        var x = 0.0;
        var y = 0.0;
        _projLat = 1.0e9;
        if (gpsOk) {
            x = localX(lon);
            y = localY(lat);
            _maxAdv = 25.0 + 2.0 * dOdo;
            project(x, y);
            if (_projLat <= OFF_LAT) {
                cand = 0.5 * (_projD * _sc) + 0.5 * (dist + dOdo);
                _offN = 0;
            } else {
                _offN += 1;
            }
        }
        if (cand > dist) {
            dist = cand;
        }

        // Confirmación en los primeros metros
        if (dist < CONF_DIST && _confN < CONF_N && gpsOk) {
            _confN += 1;
            if (_projLat <= CONF_LAT) {
                _confOk += 1;
            }
            if (_confN >= CONF_N && _confOk < CONF_OK) {
                state = ST_ARMED;
                bufReset();
                return;
            }
        }

        if (_offN >= OFF_SECS) {
            state = ST_ABORT;
            _holdUntil = System.getTimer() + HOLD_ABORT_MS;
            return;
        }

        // Afinar el instante de salida con las muestras de alrededor de la línea
        if (_refine > 0 && gpsOk) {
            bufPush(now, x * _ux + y * _uy, -x * _uy + y * _ux, x, y);
            _refine -= 1;
            if (_refine == 0) {
                _t0 = bufZero(_t0);
                bufReset();
            }
        }

        tYou = (now - _t0) / 1000.0;
        if (tYou < 0) {
            tYou = 0.0;
        }

        // Llegada: cruce de la línea final, con instante afinado igual que la salida
        if (gpsOk && _refine == 0) {
            var ex = x - _px[_n - 1];
            var ey = y - _py[_n - 1];
            bufPush(now, ex * _uex + ey * _uey, -ex * _uey + ey * _uex, x, y);
            if (_endPending < 0 && dist > ((len * 0.8 > len - END_NEAR) ? len * 0.8 : len - END_NEAR)) {
                var tg = gateCross(_uex, _uey);
                if (tg != null) {
                    _endGuess = tg;
                    _endPending = REFINE_N;
                }
            } else if (_endPending > 0) {
                _endPending -= 1;
            }
            if (_endPending == 0) {
                finish((bufZero(_endGuess) - _t0) / 1000.0);
                return;
            }
        }
        if (dist >= len + 60.0) {
            finish(tYou);
            return;
        }

        var dd = (dist < len) ? dist : len;
        var tg2 = ghostAt(dd);
        delta = tYou - tg2;
        eta = _total - tg2;
        remain = len - dd;
        dGhost = ghostDistAt(tYou);
    }

    private function finish(tFinal) as Void {
        tYou = tFinal;
        finalDelta = tFinal - _total;
        delta = finalDelta;
        eta = 0.0;
        remain = 0.0;
        dist = len;
        dGhost = len;
        state = ST_DONE;
        _holdUntil = System.getTimer() + HOLD_DONE_MS;
    }

    // ---------- Líneas de salida y llegada ----------

    private function bufReset() as Void {
        _bn = 0;
    }

    private function bufPush(t, s, c, x, y) as Void {
        if (_bn == BUF_N) {
            for (var i = 1; i < BUF_N; i++) {
                _bt[i - 1] = _bt[i];
                _bs[i - 1] = _bs[i];
                _bc[i - 1] = _bc[i];
                _bx[i - 1] = _bx[i];
                _by[i - 1] = _by[i];
            }
            _bn = BUF_N - 1;
        }
        _bt[_bn] = t.toFloat();
        _bs[_bn] = s;
        _bc[_bn] = c;
        _bx[_bn] = x;
        _by[_bn] = y;
        _bn += 1;
    }

    // Instante estimado del cruce: la última muestra está pasada la línea y alguna anterior no
    private function gateCross(ux, uy) {
        if (_bn < 2) {
            return null;
        }
        var l = _bn - 1;
        if (_bs[l] < 0 || _bs[l] > 60.0) {
            return null;
        }
        var j = -1;
        for (var i = _bn - 2; i >= 0; i--) {
            if (_bs[i] < 0) {
                j = i;
                break;
            }
        }
        if (j < 0) {
            return null;
        }
        var dt = (_bt[l] - _bt[j]) / 1000.0;
        var mx = _bx[l] - _bx[j];
        var my = _by[l] - _by[j];
        var mv = Math.sqrt(mx * mx + my * my);
        if (dt <= 0 || mv <= 0) {
            return null;
        }
        var sp = mv / dt;
        if (sp < MIN_SPEED || sp > MAX_JUMP || (mx * ux + my * uy) / mv < COS_MAX) {
            return null;
        }
        var f = -_bs[j] / (_bs[j + 1] - _bs[j]);
        var cc = _bc[j] + f * (_bc[j + 1] - _bc[j]);
        if (cc.abs() > GATE_HALF) {
            return null;
        }
        return _bt[j] + f * (_bt[j + 1] - _bt[j]);
    }

    // Recta por mínimos cuadrados sobre el búfer: instante en que la coordenada vale 0
    private function bufZero(fallback) {
        var n = 0.0;
        var sx = 0.0;
        var sy = 0.0;
        var sxx = 0.0;
        var sxy = 0.0;
        for (var i = 0; i < _bn; i++) {
            var v = _bs[i];
            if (v.abs() <= 60.0) {
                var tt = (_bt[i] - fallback) / 1000.0;
                n += 1.0;
                sx += tt;
                sy += v;
                sxx += tt * tt;
                sxy += tt * v;
            }
        }
        var den = n * sxx - sx * sx;
        if (n < 3 || den <= 0) {
            return fallback;
        }
        var b = (n * sxy - sx * sy) / den;
        var a = (sy - b * sx) / n;
        if (b < 0.5) {
            return fallback;
        }
        return fallback + (-a / b) * 1000.0;
    }

    // ---------- Distancia dentro del segmento ----------

    // Proyección sobre el recorrido, con ventana alrededor del último tramo
    private function project(x, y) as Void {
        var lo = _k - 2;
        var hi = _k + 8;
        if (lo < 0) {
            lo = 0;
        }
        if (hi > _n - 2) {
            hi = _n - 2;
        }
        var found = projectRange(x, y, lo, hi);
        if (!found || _projLat > 30.0) {
            projectRange(x, y, 0, _n - 2);
        }
    }

    private function projectRange(x, y, lo, hi) {
        var bestD = 1.0e9;
        var bestA = 0.0;
        var bestI = -1;
        for (var i = lo; i <= hi; i++) {
            var ax = _px[i];
            var ay = _py[i];
            var vx = _px[i + 1] - ax;
            var vy = _py[i + 1] - ay;
            var l2 = vx * vx + vy * vy;
            var t = 0.0;
            if (l2 > 0) {
                t = ((x - ax) * vx + (y - ay) * vy) / l2;
                if (t < 0) {
                    t = 0.0;
                } else if (t > 1) {
                    t = 1.0;
                }
            }
            var qx = ax + t * vx - x;
            var qy = ay + t * vy - y;
            var d = Math.sqrt(qx * qx + qy * qy);
            var along = _cum[i] + t * Math.sqrt(l2);
            // Ni retroceder ni saltar a otra rama de una herradura
            if (along < _projPrev - 10.0 || along > _projPrev + _maxAdv) {
                continue;
            }
            if (d < bestD) {
                bestD = d;
                bestA = along;
                bestI = i;
            }
        }
        if (bestI < 0) {
            return false;
        }
        if (bestD < _projLat) {
            _projLat = bestD;
            _projD = bestA;
            _k = bestI;
            if (bestA > _projPrev) {
                _projPrev = bestA;
            }
        }
        return true;
    }

    // ---------- Liebre ----------

    // Tiempo de la liebre (s) en la distancia d: acceso directo por paso fijo
    function ghostAt(d) {
        var gn = _g.size();
        var i = (d / _step).toNumber();
        if (i < 0) {
            i = 0;
        }
        if (i >= gn - 1) {
            return _g[gn - 1] / 10.0;
        }
        var d0 = i * _step;
        var d1 = (i + 1 == gn - 1) ? len : (i + 1) * _step;
        var f = (d1 > d0) ? (d - d0) / (d1 - d0) : 0.0;
        return (_g[i] + f * (_g[i + 1] - _g[i])) / 10.0;
    }

    // Distancia de la liebre (m) en el tiempo t: búsqueda binaria inversa
    function ghostDistAt(t) {
        var gn = _g.size();
        var tt = t * 10.0;
        if (tt <= _g[0]) {
            return 0.0;
        }
        if (tt >= _g[gn - 1]) {
            return len;
        }
        var lo = 0;
        var hi = gn - 1;
        while (hi - lo > 1) {
            var mid = (lo + hi) / 2;
            if (_g[mid] <= tt) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        var d0 = lo * _step;
        var d1 = (hi == gn - 1) ? len : hi * _step;
        var span = _g[hi] - _g[lo];
        var f = (span > 0) ? (tt - _g[lo]) / span : 0.0;
        return d0 + f * (d1 - d0);
    }

    // ---------- Datos ----------

    private function load(i) {
        var res = segResId(i);
        if (res == null) {
            return false;
        }
        var s = WatchUi.loadResource(res);
        _lat0 = s["lat0"].toDouble();
        _lon0 = s["lon0"].toDouble();
        _kx = s["kx"].toFloat();
        _ky = s["ky"].toFloat();
        len = s["len"].toFloat();
        _step = s["step"].toFloat();
        _sc = s["sc"].toFloat();
        _ux = s["u"][0].toFloat();
        _uy = s["u"][1].toFloat();
        _uex = s["ue"][0].toFloat();
        _uey = s["ue"][1].toFloat();
        _g = s["g"];
        var p = s["p"];
        _n = p.size() / 2;
        _px = new [_n];
        _py = new [_n];
        _cum = new [_n];
        for (var j = 0; j < _n; j++) {
            _px[j] = p[2 * j] / 10.0;
            _py[j] = p[2 * j + 1] / 10.0;
            if (j == 0) {
                _cum[j] = 0.0;
            } else {
                var dx = _px[j] - _px[j - 1];
                var dy = _py[j] - _py[j - 1];
                _cum[j] = _cum[j - 1] + Math.sqrt(dx * dx + dy * dy);
            }
        }
        _total = _g[_g.size() - 1] / 10.0;
        return true;
    }

    private function unload() as Void {
        _g = null;
        _px = null;
        _py = null;
        _cum = null;
        _n = 0;
        bufReset();
    }

    private function localX(lon) {
        return ((lon - _lon0) * _kx).toFloat();
    }

    private function localY(lat) {
        return ((lat - _lat0) * _ky).toFloat();
    }
}
