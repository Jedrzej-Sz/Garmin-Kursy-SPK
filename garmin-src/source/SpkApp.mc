import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class SpkApp extends Application.AppBase {
    private var _mgr as ScheduleManager?;

    function initialize() {
        AppBase.initialize();
        _mgr = new ScheduleManager();
    }

    (:glance)
    function getGlanceView() as [GlanceView] or [GlanceView, GlanceViewDelegate] or Null {
        return [ new SpkGlanceView(_mgr as ScheduleManager) ];
    }

    function getInitialView() as [Views] or [Views, InputDelegates] {
        var m = _mgr as ScheduleManager;
        return [ new SpkView(m), new SpkDelegate(m) ];
    }
}
