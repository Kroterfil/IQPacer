import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Activity;
import Toybox.Lang;

class PacerView extends WatchUi.DataField {
    private var _engine as SegmentPacerEngine;

    function initialize() {
        DataField.initialize();
        _engine = new SegmentPacerEngine("La Montaña desde el tunel");
    }

    function compute(info as Activity.Info) as Void {
        var currentDist = (info.elapsedDistance != null) ? info.elapsedDistance : 0.0;
        var currentTime = (info.elapsedTime != null) ? (info.elapsedTime / 1000.0) : 0.0;
        var targetTime = _engine.getTargetTime(currentDist);
        var delta = currentTime - targetTime;
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        dc.drawText(
            dc.getWidth() / 2,
            dc.getHeight() / 2,
            Graphics.FONT_MEDIUM,
            "Pacer Ready",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }
}
