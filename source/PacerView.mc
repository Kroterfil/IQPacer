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
const NEAR_M = 500.0;   // m: por debajo, se muestra la distancia a la salida; por encima, el dato de la actividad
// Fondo de color solo cuando te desvias mas de NEUTRO_S segundos de la liebre; dentro, fondo y numero nativos.
// Colores vivos (los del sistema de Apple: rojo del boton de grabar, verde).
const NEUTRO_S = 5;
const COLOR_AHEAD = 0x34C759;   // verde vivo: vas por delante
const COLOR_BEHIND = 0xFF3B30;  // rojo vivo: vas por detrás

class PacerView extends WatchUi.DataField {
    private var _engine;
    private var _mode = MODE_DELTA;
    private var _shown = 0;       // segundos mostrados (con histéresis)
    private var _demo = false;    // modo prueba: simula el delta (de +95 a -95 s en 80 s) para ver colores y formato sin segmento
    private var _avgSpeed = null; // m/s, media de la actividad
    private var _ascent = null;   // m, desnivel positivo acumulado de la actividad
    private var _distance = null; // m, distancia recorrida de la actividad
    private var _segState = ST_IDLE;  // estado del motor en la muestra anterior (para detectar el inicio del segmento)
    private var _wSum = 0.0;      // W*s acumulados desde la salida del segmento
    private var _wTime = 0.0;     // s acumulados con dato de potencia
    private var _wLastT = 0.0;    // tYou de la muestra anterior
    private var _wAvg = 0;        // W medios desde la salida (solo se muestra durante el segmento)
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
        }
        var d = Application.Properties.getValue("demo");
        _demo = (d != null && d == true);
    }

    // Delta simulado del modo prueba: seno de +-95 s con periodo de 80 s (pasa por la zona neutra, el rojo, el verde y el 1:xx).
    private function demoShown() as Number {
        var t = System.getTimer() / 1000.0;
        return Math.round(95.0 * Math.sin(2.0 * Math.PI * t / 80.0)).toNumber();
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

    function onUpdate(dc as Graphics.Dc) as Void {
        var st = _engine.state;
        if (_demo) {
            _shown = demoShown();
            st = ST_DONE;   // se pinta como un segmento en curso, siempre en modo delta
        }
        var nativeBg = getBackgroundColor();
        var fg = (nativeBg == Graphics.COLOR_BLACK) ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;
        var bg = nativeBg;
        var active = (st == ST_RUN || st == ST_DONE);
        if (_mode == MODE_WATTS) {
            active = (st == ST_RUN);   // al terminar el segmento vuelve la distancia de la ruta, sin congelar el resultado
        }
        if (active) {
            // Dentro de +-NEUTRO_S s de la liebre: fondo y numero nativos del Garmin (como cualquier otro campo).
            // Fuera: fondo rojo (vas detras) o verde (vas por delante) y numero blanco.
            if (_mode != MODE_WATTS && _shown.abs() > NEUTRO_S) {
                bg = (_shown > 0) ? COLOR_BEHIND : COLOR_AHEAD;
                fg = Graphics.COLOR_WHITE;
            }
        }
        dc.setColor(fg, bg);
        dc.clear();
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);

        var w = dc.getWidth();
        var h = dc.getHeight();

        if (!active) {
            // Lejos de cualquier salida (>500 m) o sin segmento: dato de la actividad
            // (delta -> velocidad media; ETA -> desnivel acumulado). Cerca: distancia a la salida.
            var far = (st == ST_COOL) || (st == ST_ABORT) || (_mode == MODE_WATTS && st == ST_DONE) || (st == ST_IDLE && (_engine.nearDist < 0 || _engine.nearDist >= NEAR_M));
            if (far && drawActivityDatum(dc, w, h)) {
                return;
            }
            drawStatus(dc, w, h, st);
            return;
        }

        var title = (_mode == MODE_ETA && st == ST_RUN) ? "ETA" : "DELTA";
        if (_mode == MODE_WATTS) {
            title = "WATIOS";
        }
        var top = drawTitle(dc, w, h, title);
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
        if (_mode == MODE_WATTS) {
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
        if (_mode == MODE_WATTS) {
            drawBig(dc, cx, cy, maxW, maxH, 0, _wAvg.format("%d"), "");
        } else if (_mode == MODE_ETA && st == ST_RUN) {
            drawBig(dc, cx, cy, maxW, maxH, 0, fmtTime(_engine.eta), "");
        } else {
            // Con fondo de color (fuera de +-NEUTRO_S) el color ya dice si vas por delante o por detras: sin signo.
            // Dentro de la zona neutra (fondo nativo) el signo es lo unico que lo indica.
            var sign = (_shown.abs() > NEUTRO_S) ? 0 : ((_shown > 0) ? 1 : ((_shown < 0) ? -1 : 0));
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
