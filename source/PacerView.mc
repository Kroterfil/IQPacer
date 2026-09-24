import Toybox.Activity;
import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.WatchUi;

const MODE_DELTA = 0;
const MODE_ETA = 1;
const COLOR_AHEAD = 0x00AA00;   // verde: vas por delante
const COLOR_BEHIND = 0xDD0000;  // rojo: vas por detrás

class PacerView extends WatchUi.DataField {
    private var _engine;
    private var _mode = MODE_DELTA;
    private var _shown = 0;       // segundos mostrados (con histéresis)
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
            bg = (_shown > 0) ? COLOR_BEHIND : COLOR_AHEAD;
        }
        dc.setColor(fg, bg);
        dc.clear();
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);

        var w = dc.getWidth();
        var h = dc.getHeight();

        if (!active) {
            drawStatus(dc, w, h, st);
            return;
        }

        // Distancia restante arriba en pequeño (si cabe) y el dato en grande
        var small = Graphics.FONT_SMALL;
        var lh = dc.getFontHeight(small);
        if (st == ST_RUN && h >= 2 * lh + 40) {
            dc.drawText(w - 8, 4, small, fmtKm(_engine.remain), Graphics.TEXT_JUSTIFY_RIGHT);
            var top = 4 + lh;
            drawMain(dc, w / 2, top + (h - top) / 2, w - 8, h - top - 4, st);
        } else {
            drawMain(dc, w / 2, h / 2, w - 8, h - 4, st);
        }
    }

    // Dato principal: delta con signo, o ETA en m:ss. Al terminar, siempre el resultado.
    private function drawMain(dc, cx, cy, maxW, maxH, st) as Void {
        if (_mode == MODE_ETA && st == ST_RUN) {
            drawBig(dc, cx, cy, maxW, maxH, 0, fmtTime(_engine.eta), "");
        } else {
            var sign = (_shown > 0) ? 1 : ((_shown < 0) ? -1 : 0);
            drawBig(dc, cx, cy, maxW, maxH, sign, _shown.abs().format("%d"), "s");
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

    // Fuera de segmento
    private function drawStatus(dc, w, h, st) as Void {
        var txt = "--";
        if (st == ST_IDLE) {
            var d = _engine.nearDist;
            if (d >= 0 && d < 10000) {
                txt = fmtKm(d);
            }
        } else if (st == ST_ARMED) {
            txt = "Salida " + _engine.nearDist.toNumber().format("%d") + " m";
        } else if (st == ST_ABORT) {
            txt = "Fuera de ruta";
        }
        var font = Graphics.FONT_LARGE;
        if (dc.getTextWidthInPixels(txt, font) > w - 8 || dc.getFontHeight(font) > h) {
            font = Graphics.FONT_SMALL;
        }
        dc.drawText(w / 2, h / 2, font, txt, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
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
