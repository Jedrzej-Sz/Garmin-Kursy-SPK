import Toybox.Application;
import Toybox.Application.Storage;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.Position;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.WatchUi;

(:glance)
class ScheduleManager {
    // PODMIEŃ <TWOJ_NICK> na swój login GitHub
    const BASE_URL = "https://<YOUR NICK>.github.io/Garmin-Kursy-SPK";

    const KEY_DATA       = "spk_data";
    const KEY_HASH       = "spk_hash";
    const KEY_LAST_CHECK = "spk_last_check";
    const SYNC_INTERVAL  = 86400; // 24h w sekundach

    // Współrzędne przystanków do automatycznego wyboru kierunku
    const KOBYLNICA_LAT = 52.4414;
    const KOBYLNICA_LON = 17.0715;
    const SRODKA_LAT    = 52.4085;
    const SRODKA_LON    = 16.9565;

    var direction as String = "dir_a"; // dir_a: Kobylnica -> Śródka, dir_b: Śródka -> Kobylnica
    var dayMode as Number = 0;         // 0=Auto, 1=robocze, 2=soboty, 3=niedziele
    var statusMsg as String = "";
    var isSyncing as Boolean = false;

    function initialize() {
        detectDirectionFromCache();
    }

    // Wybór kierunku na podstawie ostatniej znanej pozycji GPS (0 mA dodatkowego zużycia)
    function detectDirectionFromCache() as Void {
        var info = Position.getInfo();
        if (info != null && info.position != null && info.accuracy != Position.QUALITY_NOT_AVAILABLE) {
            var deg = info.position.toDegrees();
            var lat = deg[0];
            var lon = deg[1];

            // Szybki kwadrat odległości ze skalowaniem cos(52 deg) ~= 0.615
            var dLatA = lat - KOBYLNICA_LAT;
            var dLonA = (lon - KOBYLNICA_LON) * 0.615;
            var distA = dLatA * dLatA + dLonA * dLonA;

            var dLatB = lat - SRODKA_LAT;
            var dLonB = (lon - SRODKA_LON) * 0.615;
            var distB = dLatB * dLatB + dLonB * dLonB;

            direction = (distB < distA) ? "dir_b" : "dir_a";
        }
    }

    function toggleDirection() as Void {
        direction = direction.equals("dir_a") ? "dir_b" : "dir_a";
    }

    function cycleDayMode(step as Number) as Void {
        dayMode = (dayMode + step + 4) % 4;
    }

    function getDirectionLabel() as String {
        return direction.equals("dir_a") ? "412 -> Srodka" : "412 -> Kobylnica";
    }

    function getDayKey(offsetDays as Number) as String {
        if (dayMode == 1) { return "robocze"; }
        if (dayMode == 2) { return "soboty"; }
        if (dayMode == 3) { return "niedziele"; }

        var moment = Time.now().add(new Time.Duration(offsetDays * 86400));
        var info = Gregorian.info(moment, Time.FORMAT_SHORT);
        // 1 = Niedziela, 7 = Sobota, 2..6 = Pn-Pt
        if (info.day_of_week == 1) { return "niedziele"; }
        if (info.day_of_week == 7) { return "soboty"; }
        return "robocze";
    }

    function getDayLabel() as String {
        if (dayMode == 0) { return "Auto (" + getDayKey(0) + ")"; }
        if (dayMode == 1) { return "Reczny: robocze"; }
        if (dayMode == 2) { return "Reczny: soboty"; }
        return "Reczny: niedziele";
    }

    function hasData() as Boolean {
        return Storage.getValue(KEY_DATA) != null;
    }

    function getHash() as String {
        var h = Storage.getValue(KEY_HASH);
        return (h != null) ? h.toString() : "brak";
    }

    // Zwraca tablicę słowników [{:min => Number, :diff => Number, :tomorrow => Boolean}, ...]
    function getNextDepartures(count as Number) as Array<Dictionary> {
        var result = [] as Array<Dictionary>;
        var data = Storage.getValue(KEY_DATA) as Dictionary?;
        if (data == null) { return result; }

        var dirDict = data[direction] as Dictionary?;
        if (dirDict == null) { return result; }

        var nowInfo = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        var nowMin = nowInfo.hour * 60 + nowInfo.min;

        var todayArr = dirDict[getDayKey(0)] as Array<Number>?;
        if (todayArr != null && todayArr.size() > 0) {
            var idx = lowerBound(todayArr, nowMin);
            while (idx < todayArr.size() && result.size() < count) {
                var dep = todayArr[idx];
                result.add({
                    :min => dep,
                    :diff => dep - nowMin,
                    :tomorrow => false
                });
                idx++;
            }
        }

        // Jeśli na dziś nie ma już więcej kursów, dobierz z jutra
        if (result.size() < count) {
            var nextDayKey = (dayMode == 0) ? getDayKey(1) : getDayKey(0);
            var tomArr = dirDict[nextDayKey] as Array<Number>?;
            if (tomArr != null && tomArr.size() > 0) {
                var i = 0;
                while (i < tomArr.size() && result.size() < count) {
                    var dep = tomArr[i];
                    result.add({
                        :min => dep,
                        :diff => (dep + 1440) - nowMin,
                        :tomorrow => true
                    });
                    i++;
                }
            }
        }

        return result;
    }

    // Wyszukiwanie binarne O(log n)
    private function lowerBound(arr as Array<Number>, target as Number) as Number {
        var low = 0;
        var high = arr.size() - 1;
        var res = arr.size();
        while (low <= high) {
            var mid = (low + high) / 2;
            if (arr[mid] >= target) {
                res = mid;
                high = mid - 1;
            } else {
                low = mid + 1;
            }
        }
        return res;
    }

    function formatTime(totalMin as Number) as String {
        var norm = totalMin % 1440;
        var h = norm / 60;
        var m = norm % 60;
        return h.format("%02d") + ":" + m.format("%02d");
    }

    function formatDiff(diffMin as Number) as String {
        if (diffMin <= 0) { return "TERAZ"; }
        if (diffMin < 60) { return "za " + diffMin + "'"; }
        var h = diffMin / 60;
        var m = diffMin % 60;
	return h + "h" + m.format("%02d") + "'";
    }

    // =========================================================================
    // SYNCHRONIZACJA HTTPS (wywoływana tylko z pełnego widoku, nigdy z Glance)
    // =========================================================================
    function syncIfNeeded(force as Boolean) as Void {
        if (isSyncing) { return; }

        var nowSec = Time.now().value();
        var lastCheck = Storage.getValue(KEY_LAST_CHECK) as Number?;
        var noData = !hasData();

        if (!force && !noData && lastCheck != null && (nowSec - lastCheck) < SYNC_INTERVAL) {
            return;
        }

        isSyncing = true;
        statusMsg = "Sprawdzam wersje...";
        WatchUi.requestUpdate();

        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };
        Communications.makeWebRequest(Config.BASE_URL + "/version.json", null, options, method(:onVersionReceived));
    }

    function onVersionReceived(responseCode as Number, data as Dictionary or String or Null) as Void {
        if (responseCode != 200 || !(data instanceof Dictionary)) {
            isSyncing = false;
            statusMsg = "Blad ver HTTP " + responseCode;
            WatchUi.requestUpdate();
            return;
        }

        var remoteHash = data["hash"];
        var localHash = Storage.getValue(KEY_HASH);

        if (remoteHash != null && localHash != null && remoteHash.equals(localHash) && hasData()) {
            Storage.setValue(KEY_LAST_CHECK, Time.now().value());
            isSyncing = false;
            statusMsg = "Aktualny (" + remoteHash.toString().substring(0, 6) + ")";
            WatchUi.requestUpdate();
            return;
        }

        statusMsg = "Pobieram rozklad...";
        WatchUi.requestUpdate();

        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };
        Communications.makeWebRequest(Config.BASE_URL + "/schedule.json", null, options, method(:onScheduleReceived));
    }

    function onScheduleReceived(responseCode as Number, data as Dictionary or String or Null) as Void {
        isSyncing = false;
        if (responseCode == 200 && (data instanceof Dictionary)) {
            var schedData = data["data"];
            var hash = data["hash"];
            if (schedData != null && hash != null) {
                Storage.setValue(KEY_DATA, schedData);
                Storage.setValue(KEY_HASH, hash);
                Storage.setValue(KEY_LAST_CHECK, Time.now().value());
                statusMsg = "Zaktualizowano!";
                WatchUi.requestUpdate();
                return;
            }
        }
        statusMsg = "Blad sched HTTP " + responseCode;
        WatchUi.requestUpdate();
    }
}
