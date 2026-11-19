import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Timer;
import Toybox.WatchUi;

class SpkView extends WatchUi.View {
    private var _mgr as ScheduleManager;
    private var _timer as Timer.Timer;

    function initialize(mgr as ScheduleManager) {
        View.initialize();
        _mgr = mgr;
        _timer = new Timer.Timer();
    }

    function onShow() as Void {
        _mgr.syncIfNeeded(false);
        _timer.start(method(:onTick), 30000, true);
    }

    function onHide() as Void {
        _timer.stop();
    }

    function onTick() as Void {
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        // Nagłówek: linia i kierunek
        dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, (h * 0.14).toNumber(), Graphics.FONT_SMALL, _mgr.getDirectionLabel(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Podtytuł: tryb dnia
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, (h * 0.24).toNumber(), Graphics.FONT_XTINY, _mgr.getDayLabel(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Separator
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine((w * 0.15).toNumber(), (h * 0.30).toNumber(), (w * 0.85).toNumber(), (h * 0.30).toNumber());

        if (!_mgr.hasData()) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            var msg = _mgr.isSyncing ? "Pobieranie..." : "Brak danych\nPrzytrzymaj UP (Menu)";
            dc.drawText(cx, (h * 0.55).toNumber(), Graphics.FONT_SMALL, msg,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        } else {
            var deps = _mgr.getNextDepartures(4);
            if (deps.size() > 0) {
                // Najbliższy kurs (duży)
                var first = deps[0];
                var diffVal = first[:diff] as Number;
                var firstTime = _mgr.formatTime(first[:min] as Number);
                var firstDiff = _mgr.formatDiff(diffVal);
                if (first[:tomorrow] as Boolean) { firstTime = "Jutro " + firstTime; }

                var diffColor = (diffVal <= 5) ? Graphics.COLOR_ORANGE : Graphics.COLOR_GREEN;
                dc.setColor(diffColor, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, (h * 0.42).toNumber(), Graphics.FONT_MEDIUM, firstDiff,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
                dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, (h * 0.42).toNumber(), Graphics.FONT_MEDIUM, firstDiff,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, (h * 0.53).toNumber(), Graphics.FONT_SMALL, firstTime,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

                // Kolejne 3 kursy
                var nextStr = "";
                for (var i = 1; i < deps.size(); i++) {
                    if (i > 1) { nextStr += "   "; }
                    nextStr += _mgr.formatTime(deps[i][:min] as Number);
                }
                dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, (h * 0.68).toNumber(), Graphics.FONT_SMALL, nextStr,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            }
        }

        // Stopka: status sync / podpowiedź
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        var footer = _mgr.statusMsg.length() > 0 ? _mgr.statusMsg : "START: kierunek\nUP/DN: dzien";
        dc.drawText(cx, (h * 0.86).toNumber(), Graphics.FONT_XTINY, footer,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}

class SpkDelegate extends WatchUi.BehaviorDelegate {
    private var _mgr as ScheduleManager;

    function initialize(mgr as ScheduleManager) {
        BehaviorDelegate.initialize();
        _mgr = mgr;
    }

    // Przycisk START/STOP -> przełącza kierunek
    function onSelect() as Boolean {
        _mgr.toggleDirection();
        WatchUi.requestUpdate();
        return true;
    }

    // Przyciski UP / DOWN -> zmienia typ dnia (np. święto w tygodniu)
    function onNextPage() as Boolean {
        _mgr.cycleDayMode(1);
        WatchUi.requestUpdate();
        return true;
    }

    function onPreviousPage() as Boolean {
        _mgr.cycleDayMode(-1);
        WatchUi.requestUpdate();
        return true;
    }

    // Przytrzymanie UP (MENU) -> wymusza sprawdzenie wersji i pobranie z GitHub Pages
    function onMenu() as Boolean {
        _mgr.syncIfNeeded(true);
        return true;
    }
}
