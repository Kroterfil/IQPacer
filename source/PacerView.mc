import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Activity;

class PacerView extends WatchUi.DataField {
    function initialize() {
        DataField.initialize();
    }

    function compute(info as Activity.Info) as Void {
        // Vacío totalmente
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        dc.drawText(dc.getWidth() / 2, dc.getHeight() / 2, Graphics.FONT_MEDIUM, "OK", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}