using Plexit.Utils;
using Toybox.Application;
using Toybox.Communications;
using Toybox.Lang;

class PlexAPI extends Api {

    private var d_params = {};
    private var d_options = { :headers => { "Accept" => "application/json" } };
	private var d_photoSourceId = null;
	private var d_photoUsingPublic = false;
	private var d_artworkUrl = null;
	private var d_plexPhotoError = null;	// set once a Plex image request timed out
	private var d_photoTimer = null;
    private var d_request = null;
    private var d_source = null;
    private var d_syncSession = null;
    private var d_configured = false;

    function isAvailable() {
        if (!d_configured) { return false; }
        var record = PlexServers.get(d_source);
        return (record == null) || ((record["enabled"] != false)
            && (record["token"] instanceof Lang.String) && record["token"].equals(key()));
    }

    function cancelRequests() {
        if (d_request != null) { d_request.cancel(); d_request = null; }
    }

    function url() {
        var record = PlexServers.get(d_source);
        if ((record != null) && (record["token"] instanceof Lang.String)
            && record["token"].equals(key()) && (record["uri"] != null)) {
            return record["uri"];
        }
        return Api.url();
    }

    function serverRequest(requestUrl, params, options, callback) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
        if (!isAvailable()) { d_fallback.invoke(new Plexit.ApiError(Plexit.ApiError.ACCESS)); return; }
        var base = url();
        var path = requestUrl.substring(base.length(), requestUrl.length());
        // A lost response does not prove a write failed. Do not replay ratings
        // or scrobbles on another host and risk submitting the same event twice.
        var retry = (path.find("/:/scrobble") != 0)
            && (options[:method] != Communications.HTTP_REQUEST_METHOD_PUT);
        cancelRequests();
        var record = PlexServers.get(d_source);
        var urls = (retry && (record != null)) ? PlexServers.urls(record) : [base];
        if (retry && (record == null)) { urls = PlexAccount.connectionUrls(base); }
        if (urls.size() == 0) { d_fallback.invoke(new Plexit.ApiError(Plexit.ApiError.ACCESS)); return; }
        d_request = new PlexServerRequest(urls, path,
            params, options, callback, method(:onWorkingAddress), retry);
        d_request.setCompatibility(PlexServers.connectionMode(record).equals(PlexServers.CONNECTION_COMPATIBILITY));
        d_request.setFailureCallback(method(:onAddressFailure));
        d_request.start();
    }

    function onWorkingAddress(uri) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
        Api.updateUrl(uri);
        var record = PlexServers.get(d_source);
        if ((record != null) && (record["token"] instanceof Lang.String) && record["token"].equals(key())) {
            if (!uri.equals(record["uri"]) || !"online".equals(record["status"])) {
                record["uri"] = uri;
                record["status"] = "online";
                PlexServers.save(record);
            }
        }
        var active = Application.Storage.getValue(Plexit.Storage.PLEX_SERVER_ID);
        if ((active instanceof Lang.String) && active.equals(d_source)
            && !uri.equals(Application.Storage.getValue(Plexit.Storage.PLEX_SERVER_URL))) {
            Application.Storage.setValue(Plexit.Storage.PLEX_SERVER_URL, uri);
        }
    }

    function onAddressFailure(code) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
        if (PlexServerRequest.canRetry(code)) { PlexServers.status(d_source, "offline"); }
        else if ((code == 401) || (code == 403)) { PlexServers.status(d_source, "unavailable"); }
    }

    function initialize(settings, progress, fallback) {
        d_syncSession = PlexSyncSession.token();
        d_source = settings["server_id"];
        d_configured = (settings["api_url"] != null) && (settings["api_key"] != null);
        Api.initialize("");
        Api.update(settings);
		d_artworkUrl = settings.get("artwork_url");

		// set callbacks
		Api.setProgressCallback(progress);
		Api.setFallback(fallback);

		d_options[:headers].put("X-Plex-Product", "Plexit");
		d_options[:headers].put("X-Plex-Version", (new PlexitVersion(null)).toString());
		d_options[:headers].put("X-Plex-Client-Identifier", PlexAccount.clientId());
		d_options[:headers].put("X-Plex-Platform", "Garmin Connect IQ");
		d_options[:headers].put("X-Plex-Device", "Garmin Watch");
		d_options[:headers].put("X-Plex-Device-Name", "Plexit (Garmin)");
    }

    function identity(callback) {
        Api.setCallback(callback);

        var url = url() + "/identity";
		var options = d_options;

        serverRequest(url, {}, options, self.method(:onResponse));
    }

	function scrobble(callback, params) {
		Api.setCallback(callback);
		
		var url = url() + "/:/scrobble";
		var options = {
			:responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_TEXT_PLAIN,
		};
		
		// construct parameters
		params = Plexit.Utils.merge(params, d_params);
		options = Plexit.Utils.merge(options, d_options);

		serverRequest(url, params, options, self.method(:onScrobble));
	}

	function rate(callback, params) {
		Api.setCallback(callback);

		// PMS documents these as query parameters even for PUT. Garmin otherwise
		// serializes PUT parameters into the request body, which older PMS builds
		// do not consistently parse for this legacy endpoint.
		var url = url() + "/:/rate"
			+ "?key=" + params.get("key")
			+ "&identifier=com.plexapp.plugins.library"
			+ "&rating=" + params.get("rating")
			+ "&ratedAt=" + params.get("ratedAt");
		var options = {
			:method => Communications.HTTP_REQUEST_METHOD_PUT,
			:headers => d_options[:headers],
			:responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_TEXT_PLAIN,
		};
		Plexit.Utils.log("Submitting Plex rating for track " + params.get("key"));
		serverRequest(url, null, options, self.method(:onRate));
	}

	function onRate(responseCode, data) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		var error = Api.checkResponse(responseCode, data);
		if (error) {
			d_fallback.invoke(error);
			return;
		}
		d_callback.invoke(data);
	}

	function onScrobble(responseCode, data) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		var error = Api.checkResponse(responseCode, data);
		if (error) {
			d_fallback.invoke(error);
			return;
		}
		d_callback.invoke(data);
	}
	
	/*
	 * onIdentity
	 *
	 * checks Dictionary response and returns the MediaContainer element
	 */
	function onResponse(responseCode, data) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		// errors are filtered first
		var error = Api.checkDictionaryResponse(responseCode, data);
		if (error) {
			d_fallback.invoke(error);
			return;
		}
		d_callback.invoke(data["MediaContainer"]);
	}

    function playlists(callback, params) {
		Api.setCallback(callback);

        var url = url() + "/playlists";
		Plexit.Utils.log("playlists: " + url);
        params = Utils.merge(d_params, params);

        serverRequest(url, params, d_options, self.method(:onResponse));
    }

    function onPlaylists(responseCode, data) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		// check if request was successful and response is ok
    	var error = Api.checkDictionaryResponse(responseCode, data);
    	if (error) {
    		d_fallback.invoke(error);	// add function name and variables available ?
    		return;
    	}
    	
    	var response = data["MediaContainer"]["Metadata"];
		
		d_callback.invoke(response);
    }

    function playlists_items(callback, params, id) {
		Api.setCallback(callback);

        var url = url() + "/playlists/" + id + "/items";
		Plexit.Utils.log("playlists_items: " + url);
        params = Utils.merge(d_params, params);

        serverRequest(url, params, d_options, self.method(:onResponse));
    }

    function playlist(callback, params, id) {
		Api.setCallback(callback);

        var url = url() + "/playlists/" + id;
		Plexit.Utils.log("playlist: " + url);
        params = Utils.merge(d_params, params);
        serverRequest(url, params, d_options, self.method(:onResponse));
    }

    function hubs_search(callback, params) {
        Api.setCallback(callback);
        serverRequest(url() + "/hubs/search", Utils.merge(d_params, params),
            d_options, self.method(:onResponse));
    }

	function library_sections(callback, params) {
		Api.setCallback(callback);
		var requestUrl = url() + "/library/sections";
		Plexit.Utils.log("library_sections: " + requestUrl);
		serverRequest(
			requestUrl,
			Utils.merge(d_params, params),
			d_options,
			self.method(:onResponse)
		);
	}

	function library_section_all(callback, params, sectionId) {
		Api.setCallback(callback);
		var requestUrl = url() + "/library/sections/" + sectionId + "/all";
		Plexit.Utils.log("library_section_all: " + requestUrl);
		serverRequest(
			requestUrl,
			Utils.merge(d_params, params),
			d_options,
			self.method(:onResponse)
		);
	}

	function library_section_genres(callback, params, sectionId) {
		Api.setCallback(callback);
		var requestUrl = url() + "/library/sections/" + sectionId + "/genre";
		Plexit.Utils.log("library_section_genres: " + requestUrl);
		serverRequest(
			requestUrl,
			Utils.merge(d_params, params),
			d_options,
			self.method(:onResponse)
		);
	}

	function library_section_collections(callback, params, sectionId) {
		Api.setCallback(callback);
		var requestUrl = url() + "/library/sections/" + sectionId + "/collections";
		Plexit.Utils.log("library_section_collections: " + requestUrl);
		serverRequest(
			requestUrl,
			Utils.merge(d_params, params),
			d_options,
			self.method(:onResponse)
		);
	}

	function metadata(callback, params, id) {
		Api.setCallback(callback);
		var requestUrl = url() + "/library/metadata/" + id;
		Plexit.Utils.log("metadata: " + requestUrl);
		serverRequest(
			requestUrl,
			Utils.merge(d_params, params),
			d_options,
			self.method(:onResponse)
		);
	}

	function metadata_children(callback, params, id) {
		Api.setCallback(callback);
		var requestUrl = url() + "/library/metadata/" + id + "/children";
		Plexit.Utils.log("metadata_children: " + requestUrl);
		serverRequest(
			requestUrl,
			Utils.merge(d_params, params),
			d_options,
			self.method(:onResponse)
		);
	}

	function metadata_all_leaves(callback, params, id) {
		Api.setCallback(callback);
		var requestUrl = url() + "/library/metadata/" + id + "/allLeaves";
		Plexit.Utils.log("metadata_all_leaves: " + requestUrl);
		serverRequest(
			requestUrl,
			Utils.merge(d_params, params),
			d_options,
			self.method(:onResponse)
		);
	}
    
    /**
     * stream
     *
     * downloads a given media file
     */
    function stream(callback, params, id, encoding) {
		Api.setCallback(callback);
		Api.beginDownloadProgress();
		Plexit.Utils.log("Starting direct audio download");

		var url = url() + id;
		Plexit.Utils.log("Audio download URL: " + url);
		params = Plexit.Utils.merge(params, d_params);

		// additional options
		var options = {
			:method => Communications.HTTP_REQUEST_METHOD_GET,
			:headers => d_options[:headers],
          	:responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_AUDIO,
          	:mediaEncoding => encoding,
			:fileDownloadProgressCallback => method(:onProgress),
   		};

		serverRequest(url, params, options, self.method(:onStream));
	}
    
    /**
	 * Ask PMS to evaluate the exact profile before starting the expensive
	 * download. The returned decision text is invaluable when PMS rejects a
	 * client profile or transcode parameter.
	 */
	function music_transcode_decision(callback, params) {
		Api.setCallback(callback);

		var url = url() + "/music/:/transcode/universal/decision";
		Plexit.Utils.log("Plex transcode decision endpoint: /music/:/transcode/universal/decision");
		Plexit.Utils.log("Plex transcode request: path=" + params.get("path")
			+ ", protocol=" + params.get("protocol")
			+ ", bitrate=" + params.get("musicBitrate")
			+ ", directPlay=" + params.get("directPlay")
			+ ", directStream=" + params.get("directStream"));

		var profile = params.get("X-Plex-Client-Profile-Extra");
		var requestParams = Plexit.Utils.copy(params);
		requestParams.remove("X-Plex-Client-Profile-Extra");
		requestParams = Plexit.Utils.merge(requestParams, d_params);
		var options = Plexit.Utils.copy(d_options);
		var headers = Plexit.Utils.copy(d_options[:headers]);
		// PMS selects its base transcoder profile from the platform header.
		// Unknown platform/profile names can be rejected before MDE runs.
		headers.put("X-Plex-Platform", "iOS");
		headers.put("X-Plex-Device", "AppleTV");
		headers.put("X-Plex-Client-Profile-Extra", profile);
		options.put(:headers, headers);
		// PMS can return XML or an HTML error document here even when JSON was
		// requested. Read it as text so Garmin does not replace the real HTTP
		// response with INVALID_HTTP_BODY_IN_NETWORK_RESPONSE.
		options.put(:responseType, Communications.HTTP_RESPONSE_CONTENT_TYPE_TEXT_PLAIN);

		Plexit.Utils.log("Plex transcode decision url: " + url);
		// Never print requestParams/options here: both contain the Plex token.

		serverRequest(url, requestParams, options, self.method(:onTranscodeDecision));
	}

	function onTranscodeDecision(responseCode, data) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		Plexit.Utils.log("Plex transcode decision response: " + responseCode);
		if (data instanceof Lang.String) {
			var end = data.length();
			if (end > 1200) { end = 1200; }
			Plexit.Utils.log("Plex transcode decision body: " + data.substring(0, end));
		}
		d_callback.invoke(responseCode, data);
	}

    /**
     * music_transcode
     *
     * downloads a given media file
     */
    function music_transcode(callback, params, encoding) {
		Api.setCallback(callback);
		Api.beginDownloadProgress();
		Plexit.Utils.log("Starting Plex MP3 transcode download");
		Plexit.Utils.log("Plex transcode start endpoint: /music/:/transcode/universal/start.mp3");

		// A progressive HTTP MP3 response can be persisted directly by Garmin.
		// HLS start.m3u8 returns a playlist/segments and is not the requested
		// MP3 content object.
		var url = url() + "/music/:/transcode/universal/start.mp3";
		var profile = params.get("X-Plex-Client-Profile-Extra");
		var requestParams = Plexit.Utils.copy(params);
		requestParams.remove("X-Plex-Client-Profile-Extra");
		requestParams = Plexit.Utils.merge(requestParams, d_params);

		// additional options
		var headers = Plexit.Utils.copy(d_options[:headers]);
		headers.put("X-Plex-Platform", "iOS");
		headers.put("X-Plex-Device", "AppleTV");
		headers.put("X-Plex-Client-Profile-Extra", profile);
		var options = {
			:method => Communications.HTTP_REQUEST_METHOD_GET,
			:headers => headers,
          	:responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_AUDIO,
          	:mediaEncoding => encoding,
			:fileDownloadProgressCallback => method(:onProgress),
   		};

		serverRequest(url, requestParams, options, self.method(:onStream));
	}

	function onStream(responseCode, data) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		Plexit.Utils.log("Audio download completed with response " + responseCode);
		// check if request was successful and response is ok
		var error = Api.checkContentResponse(responseCode, data);
		if (error) {
    		d_fallback.invoke(error);
			return;
		}
        Api.finishDownloadProgress();
    	d_callback.invoke(data);
	}

    
    /**
     * photo transcode
     *
     * downloads artwork for given media id
     */
	function photo_transcode(callback, params, id) {
		Api.setCallback(callback);
		d_photoSourceId = id;
		d_photoUsingPublic = false;
		if (!Application.Properties.getValue("prefer_musicbrainz_artwork")) {
			startPlexPhotoTranscode();
			return;
		}

		var ratingKey = artworkRatingKey(id);
		if (ratingKey == null) {
			startPlexPhotoTranscode();
			return;
		}

		// Playlist responses do not contain the album MBID. Resolve the album
		// metadata first, then use the public Cover Art Archive image so Garmin's
		// image proxy never needs access to the user's private Plex server.
		var metadataUrl = url() + "/library/metadata/" + ratingKey;
		Plexit.Utils.log("Resolving public artwork for Plex album " + ratingKey);
		serverRequest(
			metadataUrl,
			{ "includeGuids" => 1 },
			d_options,
			method(:onArtworkMetadata)
		);
	}

	function onArtworkMetadata(responseCode, data) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		var mbid = null;
		if ((responseCode == 200) && (data instanceof Lang.Dictionary)) {
			var container = data["MediaContainer"];
			if (container instanceof Lang.Dictionary) {
				var metadata = container["Metadata"];
				if ((metadata instanceof Lang.Array) && (metadata.size() > 0)
					&& (metadata[0] instanceof Lang.Dictionary)) {
					mbid = artworkMbid(metadata[0]);
				}
			}
		}

		if (mbid == null) {
			Plexit.Utils.log("No MusicBrainz release id; trying Plex artwork");
			startPlexPhotoTranscode();
			return;
		}

		d_photoUsingPublic = true;
		var publicUrl = "https://coverartarchive.org/release/" + mbid + "/front-250";
		var options = {
			:maxWidth => 100,
			:maxHeight => 100,
			:dithering => Communications.IMAGE_DITHERING_NONE,
		};
		if (Communications has :PACKING_FORMAT_JPG) {
			options.put(:packingFormat, Communications.PACKING_FORMAT_JPG);
		}
		Plexit.Utils.log("Starting public MusicBrainz artwork download: " + mbid);
		Communications.makeImageRequest(publicUrl, null, options, method(:onPhoto));
	}

	function artworkRatingKey(id) {
		if (!(id instanceof Lang.String)) {
			return null;
		}
		var prefix = "/library/metadata/";
		if (id.find(prefix) != 0) {
			return null;
		}
		var remainder = id.substring(prefix.length(), id.length());
		var slash = remainder.find("/");
		if (slash == null) {
			return remainder;
		}
		return remainder.substring(0, slash);
	}

	function artworkMbid(metadata) {
		var guid = metadata["guid"];
		var mbid = mbidFromGuid(guid);
		if (mbid != null) {
			return mbid;
		}

		var guids = metadata["Guid"];
		if (!(guids instanceof Lang.Array)) {
			return null;
		}
		for (var index = 0; index < guids.size(); index += 1) {
			if (guids[index] instanceof Lang.Dictionary) {
				mbid = mbidFromGuid(guids[index]["id"]);
				if (mbid != null) {
					return mbid;
				}
			}
		}
		return null;
	}

	function mbidFromGuid(guid) {
		if (!(guid instanceof Lang.String) || (guid.find("mbid://") != 0)) {
			return null;
		}
		return guid.substring(7, guid.length());
	}

	function startPlexPhotoTranscode() {
		// Garmin fetches images through its own servers; when those cannot
		// reach this Plex server, every request waits ~30 s before failing.
		// Skip Plex artwork for the rest of this sync after the first timeout.
		// Fail from a timer: an immediate fallback would recurse through
		// ArtworkSync.sync() once per remaining artwork.
		if (d_plexPhotoError != null) {
			Plexit.Utils.log("Skipping Plex artwork: image request timed out earlier in this sync");
			d_photoTimer = new Toybox.Timer.Timer();
			d_photoTimer.start(method(:onPhotoSkipped), 50, false);
			return;
		}

		var imageBaseUrl = (d_artworkUrl != null) ? d_artworkUrl : url();
		var photoUrl = imageBaseUrl + "/photo/:/transcode"
			+ "?url=" + encodeArtworkPath(d_photoSourceId)
			+ "&width=99"
			+ "&height=99"
			+ "&format=jpg";

		var options = {
			:maxWidth => 101,
			:maxHeight => 101,
		};

		Plexit.Utils.log("Starting Plex artwork download via: " + photoUrl);
		Communications.makeImageRequest(photoUrl, null, options, method(:onPhoto));
	}

	function encodeArtworkPath(path) {
		var encoded = "";
		var remainder = path;
		var slash = remainder.find("/");
		while (slash != null) {
			encoded += remainder.substring(0, slash) + "%2F";
			remainder = remainder.substring(slash + 1, remainder.length());
			slash = remainder.find("/");
		}
		return encoded + remainder;
	}

	function onPhotoSkipped() {
		d_photoTimer = null;
		if (!PlexSyncSession.valid(d_syncSession)) { return; }
		d_fallback.invoke(d_plexPhotoError);
	}

	function onPhoto(responseCode, data) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		Plexit.Utils.log("Artwork download completed with response " + responseCode);
		// check if request was successful and response is ok
		var error = Api.checkImageResponse(responseCode, data);
		if (error) {
			if (d_photoUsingPublic) {
				d_photoUsingPublic = false;
				Plexit.Utils.log("Public artwork unavailable; trying Plex artwork");
				startPlexPhotoTranscode();
				return;
			}
			if (responseCode == Communications.UNKNOWN_ERROR) {
				d_plexPhotoError = error;
			}
			d_fallback.invoke(error);
			return;
		}
		d_callback.invoke(data);
	}

	// @override
	function updateKey(key) {
		Api.updateKey(key);
		d_params.put("X-Plex-Token", key);
		d_options[:headers].put("X-Plex-Token", key);
	}

	function update(settings) {
		cancelRequests();
        d_source = settings["server_id"];
        d_configured = (settings["api_url"] != null) && (settings["api_key"] != null);
		Api.update(settings);
		d_artworkUrl = settings.get("artwork_url");
	}
}
