import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class IQPacerApp extends Application.AppBase {
    private var _view = null;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
    }

    function onStop(state as Dictionary?) as Void {
    }

    function getInitialView() as [Views] or [Views, InputDelegates] {
        _view = new PacerView();
        return [ _view ];
    }

    // Cambio de ajustes desde la app Connect IQ / Garmin Express
    function onSettingsChanged() as Void {
        if (_view != null) {
            _view.loadSettings();
        }
        WatchUi.requestUpdate();
    }
}
