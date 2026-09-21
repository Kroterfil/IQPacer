import os

os.makedirs("source", exist_ok=True)

manifest_content = """<iq:manifest xmlns:iq="http://www.garmin.com/xml/connectiq/manifest" version="3">
    <iq:application id="12345678-1234-1234-1234-1234567890ab" type="datafield" name="IQPacer" entry="PacerView" version="1.0.0" minApiLevel="3.2.0">
        <iq:products>
            <iq:product id="edge1050"/>
        </iq:products>
        <iq:permissions/>
        <iq:languages>
            <iq:language>eng</iq:language>
        </iq:languages>
    </iq:application>
</iq:manifest>
"""
with open("manifest.xml", "w", encoding="utf-8") as f:
    f.write(manifest_content)

view_content = """import Toybox.WatchUi;
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
        var currentDist = (info.currentDistance != null) ? info.currentDistance : 0.0;
        var currentTime = (info.elapsedTime != null) ? (info.elapsedTime / 1000.0) : 0.0;
        var targetTime = _engine.getTargetTime(currentDist);
        var delta = currentTime - targetTime;
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        dc.drawText(dc.getWidth() / 2, dc.getHeight() / 2, Graphics.FONT_MEDIUM, "Pacer Ready", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VERTICAL);
    }
}
"""
with open("source/PacerView.mc", "w", encoding="utf-8") as f:
    f.write(view_content)

print("¡Archivos de configuración y vista generados con éxito!")
