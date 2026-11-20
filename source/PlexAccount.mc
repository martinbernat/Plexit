using Toybox.Application;
using Toybox.System;
using Toybox.Lang;
using Plexit.Storage;

module PlexAccount {
    function isConnected() {
        return (Application.Storage.getValue(Storage.PLEX_SERVER_URL) != null)
            && (Application.Storage.getValue(Storage.PLEX_SERVER_TOKEN) != null);
    }

    function clientId() {
        var id = Application.Storage.getValue(Storage.PLEX_CLIENT_ID);
        if (id != null) {
            return id;
        }

        var settings = System.getDeviceSettings();
        id = settings.uniqueIdentifier;
        if (id == null) {
            id = settings.partNumber + "-plexit";
        }
        Application.Storage.setValue(Storage.PLEX_CLIENT_ID, id);
        return id;
    }

    function headers(token) {
        var values = {
            "Accept" => "application/json",
            "X-Plex-Product" => "Plexit",
            "X-Plex-Version" => (new PlexitVersion(null)).toString(),
            "X-Plex-Client-Identifier" => clientId(),
            "X-Plex-Platform" => "Garmin Connect IQ",
            "X-Plex-Device" => "Garmin Watch",
            "X-Plex-Device-Name" => "Plexit (Garmin)",
        };
        if (token != null) {
            values.put("X-Plex-Token", token);
        }
        return values;
    }

    function connectionUrls(primary) {
        return orderedConnectionUrls(
            Application.Storage.getValue(Storage.PLEX_CUSTOM_SERVER_URL), primary,
            Application.Storage.getValue(Storage.PLEX_SERVER_URL),
            Application.Storage.getValue(Storage.PLEX_SERVER_URLS));
    }

    function orderedConnectionUrls(custom, primary, current, saved) {
        var urls = [];
        addConnectionUrl(urls, custom);
        addConnectionUrl(urls, primary);
        addConnectionUrl(urls, current);
        if (saved instanceof Lang.Array) {
            for (var i = 0; i < saved.size(); i += 1) { addConnectionUrl(urls, saved[i]); }
        }
        return urls;
    }

    function addConnectionUrl(urls, uri) {
        if (!(uri instanceof Lang.String)) { return; }
        for (var i = 0; i < urls.size(); i += 1) {
            if (urls[i].equals(uri)) { return; }
        }
        urls.add(uri);
    }

    function setServerAddress(uri) {
        Application.Storage.setValue(Storage.PLEX_CUSTOM_SERVER_URL, uri);
        var urls = connectionUrls(uri);
        Application.Storage.setValue(Storage.PLEX_SERVER_URLS, urls);
        Application.Storage.setValue(Storage.PLEX_SERVER_URL, uri);
        var record = PlexServers.get(Application.Storage.getValue(Storage.PLEX_SERVER_ID));
        if (record != null) {
            record["custom"] = uri;
            record["uri"] = uri;
            PlexServers.save(record);
        }
    }

    function setServerAddressFor(serverId, uri) {
        var active = Application.Storage.getValue(Storage.PLEX_SERVER_ID);
        if ((serverId == null) || ((active instanceof Lang.String) && active.equals(serverId))) {
            setServerAddress(uri);
            Plexit.Provider.onSettingsChanged();
            return;
        }
        var record = PlexServers.get(serverId);
        if (record != null) {
            record["custom"] = uri;
            record["uri"] = uri;
            PlexServers.save(record);
        }
    }

    function clearServerAddressFor(serverId) {
        var record = PlexServers.get(serverId);
        if ((record == null) || !(record["urls"] instanceof Lang.Array)
            || (record["urls"].size() == 0)) { return false; }
        // urls contains the discovery results, not the custom preference or
        // the last working endpoint. Reset both so automatic routing starts
        // from the advertised addresses again.
        record["custom"] = null;
        record["uri"] = record["urls"][0];
        record["status"] = "unknown";
        PlexServers.save(record);
        var active = Application.Storage.getValue(Storage.PLEX_SERVER_ID);
        if ((active instanceof Lang.String) && active.equals(serverId)) {
            PlexServers.select(serverId);
            Application.Storage.deleteValue(Storage.PLEX_CUSTOM_SERVER_URL);
        }
        return true;
    }

    function saveServer(name, uri, token, accountToken, artworkUri, urls, serverId) {
        var previousId = Application.Storage.getValue(Storage.PLEX_SERVER_ID);
        var sameServer = (previousId instanceof Lang.String) && previousId.equals(serverId);
        if (previousId == null) {
            var legacyId = Application.Storage.getValue(Storage.PLEX_LEGACY_SERVER_ID);
            var previousName = Application.Storage.getValue(Storage.PLEX_SERVER_NAME);
            var previousToken = Application.Storage.getValue(Storage.PLEX_SERVER_TOKEN);
            sameServer = ((legacyId instanceof Lang.String) && legacyId.equals(serverId))
                || ((previousName instanceof Lang.String) && previousName.equals(name)
                    && (previousToken instanceof Lang.String) && previousToken.equals(token));
        }
        if (!sameServer) { Application.Storage.deleteValue(Storage.PLEX_CUSTOM_SERVER_URL); }
        if (Application.Storage.getValue(Storage.PLEX_LEGACY_SERVER_ID) == null) {
            if (previousId != null) { Application.Storage.setValue(Storage.PLEX_LEGACY_SERVER_ID, previousId); }
            else {
                var songs = Application.Storage.getValue(Storage.SONGS);
                var playlists = Application.Storage.getValue(Storage.PLAYLISTS);
                var hasMedia = (SongStore.getIds().size() > 0)
                    || ((songs instanceof Lang.Dictionary) && (songs.size() > 0))
                    || ((playlists instanceof Lang.Dictionary) && (playlists.size() > 0));
                if (sameServer || !hasMedia) { Application.Storage.setValue(Storage.PLEX_LEGACY_SERVER_ID, serverId); }
            }
        }
        Application.Storage.setValue(Storage.PLEX_SERVER_ID, serverId);
        Application.Storage.setValue(Storage.PLEX_SERVER_NAME, name);
        Application.Storage.setValue(Storage.PLEX_SERVER_URL, uri);
        // Replace the list on sign-in: never carry URLs from another server.
        Application.Storage.setValue(Storage.PLEX_SERVER_URLS, urls);
        Application.Storage.setValue(Storage.PLEX_SERVER_TOKEN, token);
        Application.Storage.setValue(Storage.PLEX_ARTWORK_URL, artworkUri);
        Application.Storage.setValue(Storage.PLEX_ACCOUNT_TOKEN, accountToken);
        var record = PlexServers.get(serverId);
        if (record != null) {
            record["uri"] = uri;
            record["token"] = token;
            record["custom"] = Application.Storage.getValue(Storage.PLEX_CUSTOM_SERVER_URL);
            record["status"] = "online";
            PlexServers.save(record);
        }
        Plexit.Provider.onSettingsChanged();
    }
}
