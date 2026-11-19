import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

(:glance)
class SpkGlanceView extends WatchUi.GlanceView {
    private var _mgr as ScheduleManager;

    function initialize(mgr as ScheduleManager) {
        GlanceView.initialize();
        _mgr = mgr;
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var h = dc.getHeight();
        var title = _mgr.getDirectionLabel();
        
        var line2 = "Otworz aby pobrac";
        var line2Color = Graphics.COLOR_WHITE;

        if (_mgr.hasData()) {
            var deps = _mgr.getNextDepartures(1);
            if (deps.size() > 0) {
                var d = deps[0];
                var diffVal = d[:diff] as Number;
                var tStr = _mgr.formatTime(d[:min] as Number);
                var diffStr = _mgr.formatDiff(diffVal);
                line2 = diffStr + " | " + tStr;
                if (diffVal <= 5) {
                    line2Color = Graphics.COLOR_ORANGE;
                }
            } else {
                line2 = "Brak kursow";
            }
        }

	dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(0, (h * 0.28).toNumber(), Graphics.FONT_XTINY, title, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(0, (h * 0.72).toNumber(), Graphics.FONT_TINY, line2, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}
