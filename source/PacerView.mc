import Toybox.Activity;
import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.WatchUi;

const MODE_DELTA = 0;
const MODE_ETA = 1;
const MODE_WATTS = 2;
const MODE_DIST = 3;   // DIST: durante el segmento, distancia que queda hasta el final; sin segmento, velocidad instantanea; al terminar, cara
const NEAR_M = 500.0;   // m: por debajo, se muestra la distancia a la salida; por encima, el dato de la actividad
// Fondo de color solo cuando te desvias mas de NEUTRO_S segundos de la liebre; dentro, fondo y numero nativos.
// Colores vivos (los del sistema de Apple: rojo del boton de grabar, verde).
const NEUTRO_S = 5;
// ETA: cada vez que el tiempo que falta llega a un minuto exacto (XX:00: 12:00, 11:00 ... 2:00, 1:00), el campo enseña durante OBJ_SHOW_MS el
// tiempo contra el que se corre (el tiempo total de la liebre en el segmento) y vuelve a la cuenta atras.
const OBJ_SHOW_MS = 5000;
// Modo prueba: varios viajes del delta (DEMO_VIAJES_S) y luego, DEMO_RESULTADO_S s cada uno, los resultados de fin de segmento
// (tiempo, vatios medios, delta fijo en rojo y delta fijo en verde).
const DEMO_VIAJES_S = 16;
const DEMO_RESULTADO_S = 3;
const DEMO_PERIODO_S = 8;       // periodo del seno del delta simulado: es solo una demo, que pase rapido por rojo, neutro y verde
const DEMO_FASES = 14;          // 1 tiempo, 2 vatios, 3 delta rojo, 4 delta verde, 5 DIST km, 6 DIST m, 7 velocidad, 8 cara sonriente, 9 cara enfadada,
                                // 10 ETA en curso, 11 ETA: aviso OBJETIVO (amarillo), 12 V.MEDIA, 13 ALT, 14 DIST de la actividad
const DEMO_TOTAL_S = DEMO_VIAJES_S + DEMO_FASES * DEMO_RESULTADO_S;
const COLOR_AHEAD = 0x34C759;   // verde vivo: vas por delante
const COLOR_BEHIND = 0xFF3B30;  // rojo vivo: vas por detrás
const COLOR_OBJ = 0xFFE500;     // amarillo MUY vivo (casi puro, nada pastel): aviso del tiempo objetivo en el ETA (resalta, no es ni delante ni detras)

class PacerView extends WatchUi.DataField {
    private var _engine;
    private var _mode = MODE_DELTA;
    private var _shown = 0;       // segundos mostrados (con histéresis)
    private var _demo = false;    // modo prueba: simula el delta (de +95 a -95 s en 80 s) para ver colores y formato sin segmento
    private var _avgSpeed = null; // m/s, media de la actividad
    private var _ascent = null;   // m, desnivel positivo acumulado de la actividad
    private var _distance = null; // m, distancia recorrida de la actividad
    private var _speed = null;    // m/s, velocidad instantanea
    private var _segState = ST_IDLE;  // estado del motor en la muestra anterior (para detectar el inicio del segmento)
    private var _wSum = 0.0;      // W*s acumulados desde la salida del segmento
    private var _wTime = 0.0;     // s acumulados con dato de potencia
    private var _wLastT = 0.0;    // tYou de la muestra anterior
    private var _wAvg = 0;        // W medios desde la salida (solo se muestra durante el segmento)
    private var _etaPrev = -1.0;  // ETA de la muestra anterior (para detectar que cruza 4:00, 3:00, 2:00 o 1:00)
    private var _objUntil = 0;    // System.getTimer() hasta el que se enseña el tiempo objetivo
    private var _bigFonts = [
        Graphics.FONT_NUMBER_THAI_HOT,
        Graphics.FONT_NUMBER_HOT,
        Graphics.FONT_NUMBER_MEDIUM,
        Graphics.FONT_NUMBER_MILD,
        Graphics.FONT_LARGE,
        Graphics.FONT_MEDIUM,
        Graphics.FONT_SMALL
    ];

    function initialize() {
        DataField.initialize();
        _engine = new PacerEngine();
        loadSettings();
    }

    function loadSettings() as Void {
        var m = Application.Properties.getValue("mode");
        _mode = MODE_DELTA;
        if (m != null && m == MODE_ETA) {
            _mode = MODE_ETA;
        } else if (m != null && m == MODE_WATTS) {
            _mode = MODE_WATTS;
        } else if (m != null && m == MODE_DIST) {
            _mode = MODE_DIST;
        }
        var d = Application.Properties.getValue("demo");
        _demo = (d != null && d == true);
    }

    // Delta simulado del modo prueba: seno de +-95 s con periodo de 80 s (pasa por la zona neutra, el rojo, el verde y el 1:xx).
    private function demoShown() as Number {
        var t = System.getTimer() / 1000.0;
        return Math.round(95.0 * Math.sin(2.0 * Math.PI * t / DEMO_PERIODO_S)).toNumber();
    }

    function compute(info as Activity.Info) as Void {
        if (_demo) {
            _shown = demoShown();
            return;
        }
        _engine.compute(info);
        _avgSpeed = info.averageSpeed;
        _ascent = info.totalAscent;
        _distance = info.elapsedDistance;
        _speed = info.currentSpeed;
        var st = _engine.state;
        // Vatios medios del segmento: se reinician al empezar (RUN tras otro estado), se promedian por tiempo
        // mientras dura el segmento; al terminar el campo vuelve a la distancia de la ruta.
        if (st == ST_RUN) {
            if (_segState != ST_RUN) {
                _wSum = 0.0;
                _wTime = 0.0;
                _wLastT = 0.0;
                _wAvg = 0;
            }
            var dt = _engine.tYou - _wLastT;
            _wLastT = _engine.tYou;
            var pw = info.currentPower;
            if (pw != null && dt > 0 && dt < 10) {
                _wSum += pw * dt;
                _wTime += dt;
                _wAvg = Math.round(_wSum / _wTime).toNumber();
            }
        }
        _segState = st;
        if (st == ST_RUN) {
            // ETA: cada vez que el tiempo que falta pasa de mas de un minuto exacto a ese minuto o menos (XX:00, el que sea, no solo 4:00..1:00),
            // se enseña el objetivo 5 s. La marca de 0:00 (meta) no avisa, ni las que ya estan por debajo al empezar el segmento.
            if (_etaPrev >= 0) {
                var kPrev = Math.ceil(_etaPrev / 60.0).toNumber();
                var kNow = Math.ceil(_engine.eta / 60.0).toNumber();
                if (kNow >= 1 && kPrev > kNow) {
                    _objUntil = System.getTimer() + OBJ_SHOW_MS;
                }
            }
            _etaPrev = _engine.eta;
        } else {
            _etaPrev = -1.0;
            _objUntil = 0;
        }
        if (st == ST_RUN || st == ST_DONE) {
            // Redondeo con histéresis de 0,3 s para que el número no baile
            var d = _engine.delta;
            if ((d - _shown).abs() > 0.8) {
                _shown = Math.round(d).toNumber();
            }
        } else {
            _shown = 0;
        }
    }

    // Fase del modo prueba: 0 = viajes del delta; 1 tiempo, 2 vatios medios, 3 delta fijo en rojo, 4 delta fijo en verde,
    // 5 DIST en km, 6 DIST en metros, 7 velocidad instantanea, 8 cara sonriente (verde), 9 cara enfadada (rojo),
    // 10 ETA en curso, 11 aviso OBJETIVO (amarillo), 12 V.MEDIA, 13 ALT, 14 DIST de la actividad.
    private function demoPhase() as Number {
        var t = (System.getTimer() / 1000) % DEMO_TOTAL_S;
        if (t < DEMO_VIAJES_S) {
            return 0;
        }
        return 1 + ((t - DEMO_VIAJES_S) / DEMO_RESULTADO_S);
    }

    private function drawDemoResult(dc as Graphics.Dc, phase) as Void {
        var nativeBg = getBackgroundColor();
        var fg = (nativeBg == Graphics.COLOR_BLACK) ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;
        var bg = nativeBg;
        var title = "TIEMPO";
        var digits = "4:37";
        var sign = 0;
        if (phase == 1) {
            bg = COLOR_BEHIND;      // delta final +12 s: rojo en todo
            fg = Graphics.COLOR_WHITE;
        } else if (phase == 2) {
            title = "WATIOS";
            digits = "285";
            bg = COLOR_AHEAD;       // delta final dentro de +-5 s: verde
            fg = Graphics.COLOR_BLACK;
        } else if (phase == 3) {
            title = "DELTA";
            digits = "12";
            bg = COLOR_BEHIND;
            fg = Graphics.COLOR_WHITE;
        } else if (phase == 4) {
            title = "DELTA";
            digits = "12";
            sign = -1;              // por delante de la liebre: signo menos
            bg = COLOR_AHEAD;
            fg = Graphics.COLOR_BLACK;
        } else if (phase == 5) {
            title = "DIST";
            digits = "1.43";
            bg = COLOR_AHEAD;       // en el segmento el fondo lo manda el delta, como en el DELTA
            fg = Graphics.COLOR_BLACK;
        } else if (phase == 6) {
            title = "DIST";
            digits = "850";
            bg = COLOR_BEHIND;
            fg = Graphics.COLOR_WHITE;
        } else if (phase == 7) {
            title = "VEL";
            digits = "32.5";        // fuera de segmento: fondo nativo
        } else if (phase == 8) {
            title = "DIST";
            digits = "";
            bg = COLOR_AHEAD;
            fg = Graphics.COLOR_BLACK;
        } else if (phase == 9) {
            title = "DIST";
            digits = "";
            bg = COLOR_BEHIND;
            fg = Graphics.COLOR_WHITE;
        } else if (phase == 10) {
            title = "ETA";
            digits = "3:42";        // cuenta atras del ETA: fondo nativo (el color solo aparece fuera de +-5 s)
        } else if (phase == 11) {
            title = "OBJETIVO";
            digits = "8:42";        // cada XX:00 del ETA: 5 s el tiempo objetivo, fondo amarillo y numero negro (fijo, sin parpadeo)
            bg = COLOR_OBJ;
            fg = Graphics.COLOR_BLACK;
        } else if (phase == 12) {
            title = "V.MEDIA";
            digits = "28.4";        // fuera de segmento (campo DELTA): velocidad media de la actividad
        } else if (phase == 13) {
            title = "ALT";
            digits = "1234";        // fuera de segmento (campo ETA): desnivel acumulado
        } else if (phase == 14) {
            title = "DIST";
            digits = "52.3";        // fuera de segmento (campo WATIOS): distancia de la actividad en km
        }
        // Parpadea cada segundo, como el resultado real: fondo de color / fondo nativo con el numero de color.
        var el = ((System.getTimer() / 1000) % DEMO_TOTAL_S - DEMO_VIAJES_S) % DEMO_RESULTADO_S;
        if ((el % 2) != 0 && bg != nativeBg && phase != 11) {
            fg = bg;
            bg = nativeBg;
        }
        dc.setColor(fg, bg);
        dc.clear();
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        var w = dc.getWidth();
        var h = dc.getHeight();
        var top = drawTitle(dc, w, h, title);
        if (phase == 8 || phase == 9) {
            drawFace(dc, w / 2, top + (h - top) / 2, (((h - top) * 8) / 10) / 2, phase == 8);
        } else {
            drawBig(dc, w / 2, top + (h - top) / 2, w - 8, ((h - top) * 9) / 10, sign, digits, "");
        }
    }

    // Cara dibujada a mano (las fuentes del Edge no traen emoticonos): contorno, ojos y boca (sonrisa, o ceja fruncida y boca hacia abajo).
    private function drawFace(dc, cx, cy, r, happy) as Void {
        if (r < 8) {
            r = 8;
        }
        var pen = r / 8;
        if (pen < 2) {
            pen = 2;
        }
        dc.setPenWidth(pen);
        dc.drawCircle(cx, cy, r);
        var ex = (r * 38) / 100;
        var ey = cy - (r * 22) / 100;
        var er = r / 9;
        if (er < 2) {
            er = 2;
        }
        dc.fillCircle(cx - ex, ey, er);
        dc.fillCircle(cx + ex, ey, er);
        if (happy) {
            dc.drawArc(cx, cy, (r * 58) / 100, Graphics.ARC_COUNTER_CLOCKWISE, 205, 335);
        } else {
            dc.drawLine(cx - ex - er * 2, ey - er * 3, cx - ex + er * 2, ey - er);
            dc.drawLine(cx + ex + er * 2, ey - er * 3, cx + ex - er * 2, ey - er);
            dc.drawArc(cx, cy + (r * 52) / 100, (r * 38) / 100, Graphics.ARC_COUNTER_CLOCKWISE, 35, 145);
        }
        dc.setPenWidth(1);
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var st = _engine.state;
        if (_demo && demoPhase() != 0) {
            drawDemoResult(dc, demoPhase());
            return;
        }
        if (_demo) {
            _shown = demoShown();
            st = ST_DONE;   // se pinta como un segmento en curso, siempre en modo delta
        }
        var nativeBg = getBackgroundColor();
        var fg = (nativeBg == Graphics.COLOR_BLACK) ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;
        var bg = nativeBg;
        var active = (st == ST_RUN || st == ST_DONE);
        var mostrandoObj = (_mode == MODE_ETA && st == ST_RUN && !_demo && System.getTimer() < _objUntil);
        if (mostrandoObj) {
            // Aviso del tiempo objetivo (cada XX:00 del ETA): fondo amarillo con el numero en negro, durante 5 s
            bg = COLOR_OBJ;
            fg = Graphics.COLOR_BLACK;
        } else if (st == ST_DONE && !_demo) {
            // Resultado de fin de segmento (delta, tiempo o vatios): el fondo lo manda el delta final en todos los campos.
            // Rojo si fue mas de NEUTRO_S s por detras; verde si fue por delante o dentro de +-NEUTRO_S s.
            // Parpadea cada segundo: fondo de color con numero blanco / fondo nativo con numero de color.
            var c = (_engine.finalDelta > NEUTRO_S) ? COLOR_BEHIND : COLOR_AHEAD;
            if ((((System.getTimer() - _engine.doneAt) / 1000) % 2) == 0) {
                bg = c;
                fg = (c == COLOR_AHEAD) ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE;   // negro sobre verde (mas legible)
            } else {
                fg = c;
            }
        } else if (active && _shown.abs() > NEUTRO_S) {
            // Dentro de +-NEUTRO_S s de la liebre: fondo y numero nativos del Garmin (como cualquier otro campo).
            // Fuera: fondo rojo (vas detras) o verde (vas por delante) y numero blanco, en TODOS los campos (tambien WATIOS).
            bg = (_shown > 0) ? COLOR_BEHIND : COLOR_AHEAD;
            fg = (_shown > 0) ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;   // negro sobre verde: mas legible
        }
        dc.setColor(fg, bg);
        dc.clear();
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);

        var w = dc.getWidth();
        var h = dc.getHeight();

        if (!active) {
            // Lejos de cualquier salida (>500 m) o sin segmento: dato de la actividad
            // (delta -> velocidad media; ETA -> desnivel acumulado). Cerca: distancia a la salida.
            var far = (st == ST_COOL) || (st == ST_ABORT) || (st == ST_IDLE && (_engine.nearDist < 0 || _engine.nearDist >= NEAR_M));
            if (far && drawActivityDatum(dc, w, h)) {
                return;
            }
            drawStatus(dc, w, h, st);
            return;
        }

        // Al terminar el segmento (HOLD_DONE_MS) se queda el resultado: delta final, tiempo del segmento (ETA) o vatios medios (WATIOS).
        var title = (_mode == MODE_ETA && st == ST_RUN) ? (mostrandoObj ? "OBJETIVO" : "ETA") : ((_mode == MODE_ETA && st == ST_DONE) ? "TIEMPO" : "DELTA");
        if (_mode == MODE_WATTS) {
            title = "WATIOS";
        } else if (_mode == MODE_DIST) {
            title = "DIST";
        }
        var top = drawTitle(dc, w, h, title);
        if (_mode == MODE_DIST && st == ST_DONE) {
            // Fin de segmento: sonriente si el fondo es verde (por delante o dentro de +-NEUTRO_S s), enfadada si es rojo.
            drawFace(dc, w / 2, top + (h - top) / 2, (((h - top) * 8) / 10) / 2, _engine.finalDelta <= NEUTRO_S);
            return;
        }
        drawMain(dc, w / 2, top + (h - top) / 2, w - 8, ((h - top) * 9) / 10, st);
    }

    // Titulo como en los campos nativos: letra mas pequena, algo separada del borde superior (un octavo del alto) y
    // el numero debajo. Devuelve el alto ocupado (0 si no cabe).
    private function drawTitle(dc, w, h, title) as Number {
        var fonts = [Graphics.FONT_SMALL, Graphics.FONT_TINY, Graphics.FONT_XTINY];
        var margin = h / 8;
        if (margin < 4) {
            margin = 4;
        }
        for (var i = 0; i < fonts.size(); i++) {
            var f = fonts[i];
            var th = dc.getFontHeight(f);
            if (th * 3 + 12 <= h && dc.getTextWidthInPixels(title, f) <= w - 8) {
                dc.drawText(w / 2, margin, f, title, Graphics.TEXT_JUSTIFY_CENTER);
                return th + margin;
            }
        }
        return 0;
    }

    private function drawActivityDatum(dc, w, h) as Boolean {
        var digits = "0";
        if (_mode == MODE_DIST) {
            digits = "0.0";
            if (_speed != null) {
                var t = (_speed * 36.0).toNumber();   // decimas de km/h
                digits = (t / 10).format("%d") + "." + (t % 10).format("%d");
            }
            var topV = drawTitle(dc, w, h, "VEL");
            drawBig(dc, w / 2, topV + (h - topV) / 2, w - 8, ((h - topV) * 9) / 10, 0, digits, "");
            return true;
        } else if (_mode == MODE_WATTS) {
            digits = "0.0";
            if (_distance != null) {
                var t = (_distance / 100.0).toNumber();   // décimas de km
                digits = (t / 10).format("%d") + "." + (t % 10).format("%d");
            }
        } else if (_mode == MODE_ETA) {
            if (_ascent != null) {
                digits = _ascent.toNumber().format("%d");
            }
        } else {
            digits = "0.0";
            if (_avgSpeed != null) {
                var t = (_avgSpeed * 36.0).toNumber();   // décimas de km/h
                digits = (t / 10).format("%d") + "." + (t % 10).format("%d");
            }
        }
        var top = drawTitle(dc, w, h, (_mode == MODE_WATTS) ? "DIST" : ((_mode == MODE_ETA) ? "ALT" : "V.MEDIA"));
        // Numero algo mas pequeno que antes y centrado en el hueco bajo el titulo (como el campo nativo); sin unidades.
        drawBig(dc, w / 2, top + (h - top) / 2, w - 8, ((h - top) * 9) / 10, 0, digits, "");
        return true;
    }

    // Dato principal: delta con signo, o ETA en m:ss. Al terminar, siempre el resultado.
    private function drawMain(dc, cx, cy, maxW, maxH, st) as Void {
        if (_mode == MODE_DIST) {
            // Distancia que queda: en km con dos decimales a partir de 1 km (1.43); por debajo, metros enteros. Sin unidades.
            var rem = _engine.remain;
            if (rem < 0) {
                rem = 0.0;
            }
            if (rem >= 1000) {
                var t = (rem / 10.0).toNumber();   // centesimas de km
                drawBig(dc, cx, cy, maxW, maxH, 0, (t / 100).format("%d") + "." + (t % 100).format("%02d"), "");
            } else {
                drawBig(dc, cx, cy, maxW, maxH, 0, rem.toNumber().format("%d"), "");
            }
        } else if (_mode == MODE_WATTS) {
            drawBig(dc, cx, cy, maxW, maxH, 0, _wAvg.format("%d"), "");
        } else if (_mode == MODE_ETA && st == ST_RUN) {
            // Aviso de marca (4:00, 3:00, 2:00, 1:00): 5 s el tiempo contra el que se corre; despues, la cuenta atras
            drawBig(dc, cx, cy, maxW, maxH, 0, fmtTime((System.getTimer() < _objUntil) ? _engine.target : _engine.eta), "");
        } else if (_mode == MODE_ETA && st == ST_DONE) {
            drawBig(dc, cx, cy, maxW, maxH, 0, fmtTime(_engine.tYou), "");
        } else {
            // Por delante de la liebre siempre lleva el signo menos (-12), tambien con fondo verde. Por detras, con fondo rojo va sin signo;
            // dentro de la zona neutra (fondo nativo) el signo (+ o -) es lo unico que lo indica.
            var sign = (_shown < 0) ? -1 : ((_shown.abs() > NEUTRO_S) ? 0 : ((_shown > 0) ? 1 : 0));
            // A partir de 1 minuto, m:ss (1:01), igual que la ETA; por debajo, los segundos a secas.
            var a = _shown.abs();
            drawBig(dc, cx, cy, maxW, maxH, sign, (a >= 60) ? fmtTime(a) : a.format("%d"), "");
        }
    }

    // Las fuentes de numeros del Edge dibujan el separador decimal como una coma grande: el punto se dibuja a mano
    // (un cuadrado sobre la linea base, como el signo) y los digitos a cada lado con la fuente.
    private function dotSize(dc, f) as Number {
        var d = dc.getFontHeight(f) / 9;
        return (d < 3) ? 3 : d;
    }

    private function numWidth(dc, digits, f) as Number {
        var p = digits.find(".");
        if (p == null) {
            return dc.getTextWidthInPixels(digits, f);
        }
        var a = digits.substring(0, p);
        var b = digits.substring(p + 1, digits.length());
        var d = dotSize(dc, f);
        return dc.getTextWidthInPixels(a, f) + d + 2 * (d / 2 + 1) + dc.getTextWidthInPixels(b, f);
    }

    private function drawNum(dc, x, cy, f, digits) as Void {
        var flags = Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER;
        var p = digits.find(".");
        if (p == null) {
            dc.drawText(x, cy, f, digits, flags);
            return;
        }
        var a = digits.substring(0, p);
        var b = digits.substring(p + 1, digits.length());
        var d = dotSize(dc, f);
        var g = d / 2 + 1;
        dc.drawText(x, cy, f, a, flags);
        x += dc.getTextWidthInPixels(a, f) + g;
        var base = cy + dc.getFontHeight(f) / 2 - dc.getFontDescent(f);
        dc.fillRectangle(x, base - d, d, d);
        x += d + g;
        dc.drawText(x, cy, f, b, flags);
    }

    // Número grande: signo dibujado (no depende de la fuente) + dígitos + unidad
    private function drawBig(dc, cx, cy, maxW, maxH, sign, digits, unit) as Void {
        var unitFont = Graphics.FONT_MEDIUM;
        var uw = (unit.length() > 0) ? dc.getTextWidthInPixels(unit, unitFont) : 0;
        var font = _bigFonts[_bigFonts.size() - 1];
        var fh = dc.getFontHeight(font);
        var tw = numWidth(dc, digits, font);
        var sw = 0;
        var gap = 0;
        for (var i = 0; i < _bigFonts.size(); i++) {
            var f = _bigFonts[i];
            var h = dc.getFontHeight(f);
            var t = numWidth(dc, digits, f);
            var s = (sign != 0) ? (h * 0.3).toNumber() : 0;
            var gp = (h / 12) + 2;
            var tot = s + (sign != 0 ? gp : 0) + t + (uw > 0 ? gp + uw : 0);
            if (tot <= maxW && h * 0.75 <= maxH) {
                font = f;
                fh = h;
                tw = t;
                sw = s;
                gap = gp;
                break;
            }
        }
        var total = sw + (sign != 0 ? gap : 0) + tw + (uw > 0 ? gap + uw : 0);
        var x = cx - total / 2;
        if (sign != 0) {
            var th = (fh / 14) + 2;
            dc.fillRectangle(x, cy - th / 2, sw, th);
            if (sign > 0) {
                dc.fillRectangle(x + sw / 2 - th / 2, cy - sw / 2, th, sw);
            }
            x += sw + gap;
        }
        drawNum(dc, x, cy, font, digits);
        x += tw;
        if (uw > 0) {
            dc.drawText(x + gap, cy + fh / 6, unitFont, unit, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    // Fuera de segmento: de texto largo a corto hasta que quepa en el hueco
    private function drawStatus(dc, w, h, st) as Void {
        var opts = ["--"];
        if (st == ST_IDLE) {
            var d = _engine.nearDist;
            if (d >= 0 && d < 10000) {
                var shortTxt = d.toNumber().format("%d");
                if (d >= 1000) {
                    var t = (d / 100).toNumber();
                    shortTxt = (t / 10).format("%d") + "." + (t % 10).format("%d");
                }
                opts = [fmtKm(d), shortTxt];
            }
        } else if (st == ST_ARMED) {
            var m = _engine.nearDist.toNumber().format("%d");
            opts = [m + " m", m];
        } else if (st == ST_ABORT) {
            opts = ["Fuera de ruta", "Fuera", "X"];
        }
        var fonts = [Graphics.FONT_LARGE, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL];
        for (var i = 0; i < opts.size(); i++) {
            for (var j = 0; j < fonts.size(); j++) {
                if (dc.getTextWidthInPixels(opts[i], fonts[j]) <= w - 8 && dc.getFontHeight(fonts[j]) <= h) {
                    dc.drawText(w / 2, h / 2, fonts[j], opts[i], Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
                    return;
                }
            }
        }
        var last = opts[opts.size() - 1];
        dc.drawText(w / 2, h / 2, Graphics.FONT_XTINY, last, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ---------- Formatos ----------

    private function fmtTime(t) {
        if (t < 0) {
            t = 0;
        }
        var n = t.toNumber();
        return (n / 60).format("%d") + ":" + (n % 60).format("%02d");
    }

    private function fmtKm(m) {
        if (m < 1000) {
            return m.toNumber().format("%d") + " m";
        }
        var tenths = (m / 100).toNumber();
        return (tenths / 10).format("%d") + "." + (tenths % 10).format("%d") + " km";
    }

}
