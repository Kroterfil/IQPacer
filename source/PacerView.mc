import Toybox.Activity;
import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.WatchUi;

const MODE_DELTA = 0;
const MODE_ETA = 1;
const NEAR_M = 500.0;   // m: por debajo, se muestra la distancia a la salida; por encima, el dato de la actividad
// KSE_IQPACER_FONDO_NEGRO_NUMERO_COLOR_V1: antes eran oscuros (pensados
// como FONDO con texto blanco encima); ahora el numero va sobre negro,
// necesitan ser vivos para leerse bien.
const COLOR_AHEAD = 0x00C060;   // verde vivo: vas por delante
const COLOR_BEHIND = 0xFF3B30;  // rojo vivo: vas por detrás

class PacerView extends WatchUi.DataField {
    private var _engine;
    private var _mode = MODE_DELTA;
    private var _shown = 0;       // segundos mostrados (con histéresis)
    private var _avgSpeed = null; // m/s, media de la actividad
    private var _ascent = null;   // m, desnivel positivo acumulado de la actividad
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
        _mode = (m != null && m == MODE_ETA) ? MODE_ETA : MODE_DELTA;
    }

    function compute(info as Activity.Info) as Void {
        _engine.compute(info);
        _avgSpeed = info.averageSpeed;
        _ascent = info.totalAscent;
        var st = _engine.state;
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
        var nativeBg = getBackgroundColor();
        var fg = (nativeBg == Graphics.COLOR_BLACK) ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;
        var bg = nativeBg;
        var active = (st == ST_RUN || st == ST_DONE);
        if (active) {
            // KSE_IQPACER_FONDO_NEGRO_NUMERO_COLOR_V1: David -- fondo
            // siempre negro (menos "alarma visual" constante que el
            // rojo/verde a pantalla completa); el numero es el que
            // cambia de color. Blanco si estas dentro de +-5s de la
            // liebre (ni por delante ni por detras de sobra), rojo si
            // vas detras mas de 5s, verde si vas por delante mas de 5s.
            bg = Graphics.COLOR_BLACK;
            if (_shown.abs() <= 5) {
                fg = Graphics.COLOR_WHITE;
            } else if (_shown > 0) {
                fg = COLOR_BEHIND;
            } else {
                fg = COLOR_AHEAD;
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
            var far = (st == ST_COOL) || (st == ST_ABORT) || (st == ST_IDLE && (_engine.nearDist < 0 || _engine.nearDist >= NEAR_M));
            if (far && drawActivityDatum(dc, w, h)) {
                return;
            }
            drawStatus(dc, w, h, st);
            return;
        }

        var title = (_mode == MODE_ETA && st == ST_RUN) ? "ETA" : "DELTA";
        var top = drawTitle(dc, w, h, title);
        drawMain(dc, w / 2, top + (h - top) / 2, w - 8, h - top - 4, st);
    }

    // Título arriba, con letra del tamaño de los campos nativos (la mayor que quepa y deje sitio al número).
    // Devuelve el alto ocupado (0 si no cabe).
    private function drawTitle(dc, w, h, title) as Number {
        var fonts = [Graphics.FONT_MEDIUM, Graphics.FONT_SMALL, Graphics.FONT_TINY, Graphics.FONT_XTINY];
        for (var i = 0; i < fonts.size(); i++) {
            var f = fonts[i];
            var th = dc.getFontHeight(f);
            if (th * 3 + 12 <= h && dc.getTextWidthInPixels(title, f) <= w - 8) {
                dc.drawText(w / 2, 4, f, title, Graphics.TEXT_JUSTIFY_CENTER);
                return th + 4;
            }
        }
        return 0;
    }

    private function drawActivityDatum(dc, w, h) as Boolean {
        var digits = "0";
        var unit = "";
        if (_mode == MODE_ETA) {
            unit = "m";
            if (_ascent != null) {
                digits = _ascent.toNumber().format("%d");
            }
        } else {
            unit = "km/h";
            digits = "0,0";
            if (_avgSpeed != null) {
                var t = (_avgSpeed * 36.0).toNumber();   // décimas de km/h
                digits = (t / 10).format("%d") + "," + (t % 10).format("%d");
            }
        }
        var top = drawTitle(dc, w, h, (_mode == MODE_ETA) ? "ALT" : "V.MEDIA");
        if (top > 0) {
            unit = "";   // el título ya lo dice: más sitio para el número
        }
        drawBig(dc, w / 2, top + (h - top) / 2, w - 8, h - top - 4, 0, digits, unit);
        return true;
    }

    // Dato principal: delta con signo, o ETA en m:ss. Al terminar, siempre el resultado.
    private function drawMain(dc, cx, cy, maxW, maxH, st) as Void {
        if (_mode == MODE_ETA && st == ST_RUN) {
            drawBig(dc, cx, cy, maxW, maxH, 0, fmtTime(_engine.eta), "");
        } else {
            var sign = (_shown > 0) ? 1 : ((_shown < 0) ? -1 : 0);
            drawBig(dc, cx, cy, maxW, maxH, sign, _shown.abs().format("%d"), "");
        }
    }

    // Número grande: signo dibujado (no depende de la fuente) + dígitos + unidad
    private function drawBig(dc, cx, cy, maxW, maxH, sign, digits, unit) as Void {
        var unitFont = Graphics.FONT_MEDIUM;
        var uw = (unit.length() > 0) ? dc.getTextWidthInPixels(unit, unitFont) : 0;
        var font = _bigFonts[_bigFonts.size() - 1];
        var fh = dc.getFontHeight(font);
        var tw = dc.getTextWidthInPixels(digits, font);
        var sw = 0;
        var gap = 0;
        for (var i = 0; i < _bigFonts.size(); i++) {
            var f = _bigFonts[i];
            var h = dc.getFontHeight(f);
            var t = dc.getTextWidthInPixels(digits, f);
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
        dc.drawText(x, cy, font, digits, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
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
                    shortTxt = (t / 10).format("%d") + "," + (t % 10).format("%d");
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
        return (tenths / 10).format("%d") + "," + (tenths % 10).format("%d") + " km";
    }

}
