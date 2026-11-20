using Toybox.Communications;
using Toybox.Timer;
using Toybox.Application;

// Bind callbacks to their request so cancelled owners cannot receive stale results.
class PlexServerAttempt {
    private var d_request;
    private var d_number;
    function initialize(request, number) { d_request = request; d_number = number; }
    function response(code, data) { d_request.onAttemptResponse(d_number, code, data); }
    function progress(bytes, total) { d_request.onAttemptProgress(d_number, bytes, total); }

}

// One bounded retry chain per request. The original path, parameters and
// download options survive a change of server address unchanged.
class PlexServerRequest {
    private var d_urls;
    private var d_path;
    private var d_params;
    private var d_options;
    private var d_callback;
    private var d_selected;
    private var d_retry;
    private var d_index = 0;
    private var d_failure = null;
    private var d_timer = null;
    private var d_attempt = 0;
    private var d_compatibility;
    private var d_syncSession = null;

    function setFailureCallback(callback) { d_failure = callback; }
    function setCompatibility(enabled) { d_compatibility = enabled; }

    function scheduleRetry() {
        // Only schedule after the real transport callback. Do not manufacture a
        // timeout while the previous network operation is still running.
        if (d_compatibility) {
            Plexit.Utils.log("Plex connection recovery: waiting 60 seconds before next address");
            waitBeforeRetry(60000);
        } else { start(); }
    }

    function waitBeforeRetry(milliseconds) {
        d_timer = new Timer.Timer();
        d_timer.start(method(:start), milliseconds, false);
    }

    function initialize(urls, path, params, options, callback, selected, retry) {
        d_syncSession = PlexSyncSession.token();
        d_urls = urls;
        d_path = path;
        d_params = params;
        d_options = options;
        d_callback = callback;
        d_selected = selected;
        d_retry = retry;
        d_compatibility = false;
    }

    function start() {
        if ((d_callback == null) || !PlexSyncSession.valid(d_syncSession)) { return; }
        stopTimer();
        sendRequest(d_urls[d_index] + d_path, d_params, d_options);
    }

    function cancel() { stopTimer(); d_callback = null; }

    function stopTimer() {
        if (d_timer != null) { d_timer.stop(); d_timer = null; }
    }

    function sendRequest(url, params, options) {
        d_attempt += 1;
        var attempt = new PlexServerAttempt(self, d_attempt);
        var requestOptions = options;
        if (options[:fileDownloadProgressCallback] != null) {
            requestOptions = Plexit.Utils.copy(options);
            requestOptions[:fileDownloadProgressCallback] = attempt.method(:progress);
        }
        Communications.makeWebRequest(url, params, requestOptions, attempt.method(:response));
    }

    function onAttemptProgress(number, bytes, total) {
        if (!PlexSyncSession.valid(d_syncSession) || (number != d_attempt) || (d_callback == null)) { return; }
        var progress = d_options[:fileDownloadProgressCallback];
        if (progress != null) { progress.invoke(bytes, total); }
    }

    function onAttemptResponse(number, code, data) {
        if (!PlexSyncSession.valid(d_syncSession) || (number != d_attempt) || (d_callback == null)) { return; }
        // Ignore duplicate callbacks from an already completed attempt.
        d_attempt += 1;
        onResponse(code, data);
    }

    static function isResponseTooBig(code) {
        return (code == Communications.NETWORK_RESPONSE_TOO_LARGE)
            || (code == Communications.NETWORK_RESPONSE_OUT_OF_MEMORY);
    }

    static function canRetry(code) {
        // Never turn cancellation, response-size limits, invalid media or
        // authentication errors into a new network request.
        return (code == Communications.UNKNOWN_ERROR)
            || (code == Communications.BLE_ERROR)
            || (code == Communications.BLE_NO_DATA)
            || (code == Communications.BLE_HOST_TIMEOUT)
            || (code == Communications.BLE_SERVER_TIMEOUT)
            || (code == Communications.BLE_CONNECTION_UNAVAILABLE)
            || (code == Communications.NETWORK_REQUEST_TIMED_OUT)
            || (code == Communications.REQUEST_CONNECTION_DROPPED)
            || (code == Communications.SECURE_CONNECTION_REQUIRED)
            || (code == 502) || (code == 503) || (code == 504);
    }

    function onResponse(code, data) {
        if ((d_callback == null) || !PlexSyncSession.valid(d_syncSession)) { return; }
        stopTimer();
        // An unreachable endpoint can surface as HTTP 404 in the simulator
        // or an intermediary. Try the same read on the other addresses of
        // this server before declaring the item missing. A final 404 still
        // reaches the caller unchanged; writes are never replayed.
        if (d_retry && (canRetry(code) || (code == 404)) && ((d_index + 1) < d_urls.size())) {
            d_index += 1;
            Plexit.Utils.log("Plex connection failed (" + code + "); trying address "
                + (d_index + 1) + "/" + d_urls.size());
            scheduleRetry();
            return;
        }
        var callback = d_callback;
        d_callback = null;
        if ((code >= 200) && (code < 300)) { d_selected.invoke(d_urls[d_index]); }
        else if (d_failure != null) { d_failure.invoke(code); }
        callback.invoke(code, data);
    }
}
