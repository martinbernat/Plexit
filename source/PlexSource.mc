using Toybox.Application;
using Toybox.Lang;

// Keep legacy IDs intact for the original server, including downloaded media
// references. Other servers get a stable namespace before their Plex item key.
module PlexSource {
    function prefixLength(id) {
        var prefixes = ["album:", "artist:", "collection:", "genre:", "mix:"];
        for (var i = 0; i < prefixes.size(); i += 1) {
            if (id.find(prefixes[i]) == 0) { return prefixes[i].length(); }
        }
        return 0;
    }

    function encode(serverId, id) {
        if (id == null) { return null; }
        id = id.toString();
        var prefix = prefixLength(id);
        return id.substring(0, prefix) + serverId + "|" + id.substring(prefix, id.length());
    }

    function qualify(serverId, id) {
        var legacy = Application.Storage.getValue(Plexit.Storage.PLEX_LEGACY_SERVER_ID);
        return qualifyWithLegacy(serverId, id, legacy);
    }

    function qualifyWithLegacy(serverId, id, legacy) {
        if (id == null) { return null; }
        if ((serverId == null) || ((legacy instanceof Lang.String) && legacy.equals(serverId))) {
            return id.toString();
        }
        return encode(serverId, id);
    }

    function explicitServer(id) {
        if (!(id instanceof Lang.String)) { return null; }
        var bar = id.find("|");
        if (bar == null) { return null; }
        return id.substring(prefixLength(id), bar);
    }

    function serverId(id) {
        var explicit = explicitServer(id);
        if (explicit != null) { return explicit; }
        return implicitServer();
    }

    function sameServer(a, b) {
        return (a == null) ? (b == null) : a.equals(b);
    }

    // Server owning IDs without an explicit server prefix.
    function implicitServer() {
        var legacy = Application.Storage.getValue(Plexit.Storage.PLEX_LEGACY_SERVER_ID);
        if (legacy != null) { return legacy; }
        var records = Application.Storage.getValue(Plexit.Storage.PLEX_SERVERS);
        // If migration cannot identify the original source, never reinterpret
        // its old IDs as belonging to whichever server the user selects next.
        if ((records instanceof Lang.Array) && (records.size() > 0)) { return null; }
        return Application.Storage.getValue(Plexit.Storage.PLEX_SERVER_ID);
    }

    function raw(id) {
        if (!(id instanceof Lang.String)) { return id; }
        var bar = id.find("|");
        if (bar == null) { return id; }
        return id.substring(0, prefixLength(id)) + id.substring(bar + 1, id.length());
    }

    function belongsTo(id, server) {
        var source = serverId(id);
        return ((source == null) && (server == null))
            || ((source instanceof Lang.String) && source.equals(server));
    }
}
