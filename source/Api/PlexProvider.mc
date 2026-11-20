using Plexit.Utils;

class PlexProvider {

    private var d_api;
    private var d_source;
    private var d_syncSession = null;

    // callbacks
    private var d_callback;  // callback for finished request
    private var d_fallback;  // fallback for failed request
    private var d_progress;  // intermediate callback to update request progress

	// request variables needed to repeat the request if necessary
	private var d_action = null;
    private var d_params = {};  // stores the last request parameters
    
    enum { MAX_COUNT = 10000, MAX_LIMIT = 20, OFFSET = 0, }
    private var d_limit = MAX_LIMIT;    // defines the number of results in a single response
    private var d_offset = OFFSET;      // defines the offset for the ranged request
	private var d_count = MAX_COUNT;	// defines the number of objects to be received in ranged requests

	private var d_id;       // required for getPlaylist, getPlaylistSongs, getRefId, getArtwork
	private var d_mediaKey;			// Plex Part key used for direct downloads
	private var d_trackSeconds = 0;
	private var d_directStream = false;	// retry a failed direct MP3 download through Plex transcoding
	private var d_response;				// construct full response
	private var d_collectionType = null;
	private var d_sectionIds = [];
	private var d_sectionIndex = 0;
	private var d_dynamicBytes = 0;
    
	enum {
		PLEX_PING,
		PLEX_RECORD_PLAY,
		PLEX_RATE,
		PLEX_PLAYLIST,
		PLEX_PLAYLISTS,
		PLEX_PLAYLIST_SONGS,
		PLEX_TRANSCODE_DECISION,
		PLEX_STREAM,
		PLEX_GET_ART,
		PLEX_LIBRARY_SECTIONS,
		PLEX_LIBRARY_ITEMS,
		PLEX_LIBRARY_METADATA,
		PLEX_LIBRARY_SONGS,
		PLEX_DYNAMIC_METADATA,
		PLEX_DYNAMIC_SONGS,
		PLEX_LIBRARY_GENRES,
		PLEX_LIBRARY_COLLECTIONS,
	}

    function initialize(settings) {
        d_syncSession = PlexSyncSession.token();
        d_source = settings["server_id"];
        d_api = new PlexAPI(
            settings,
            self.method(:onProgress),
            self.method(:onError)
        );
    }
	
	function onSettingsChanged(settings) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
        d_source = settings["server_id"];
		d_api.update(settings);
	}

	// functions:
	// - ping				returns an object with server version
	// - recordPlay			submit a play
	// - getAllPlaylists	returns an array of all Plex music playlists
	// - getPlaylist		returns an array of one playlist object for id
	// - getPlaylistSongs	returns an array of songs on the playlist with id
	// - getRefId			returns a refId for a song by id (this downloads the song)
	// - getArtwork			returns a BitmapResource for a song id
	//
	// to be added in the future:
	// - getUpdatedPlaylists - returns array of all playlists updated since Moment

    /**
     * ping
     * 
     * returns an object with server version
     */
    function ping(callback) {
        d_callback = callback;

        d_action = PLEX_PING;
        do_();
    }

	function on_do_ping(response) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		d_action = null;
		d_callback.invoke(response);
	}

    /**
     * recordPlay
     * 
     * submit a play
     */
	function recordPlay(id, time, callback) {
		d_callback = callback;
		
		d_params = {
			"key" => PlexSource.raw(id),
            "identifier" => "com.plexapp.plugins.library"
		};
		
		d_action = PLEX_RECORD_PLAY;
		do_();
	}

	function on_do_record_play(response) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		d_action = null;
		d_callback.invoke(response); // expected empty response
	}

	function rate(id, value, ratedAt, callback) {
		d_callback = callback;
		d_params = {
			"key" => PlexSource.raw(id),
			"identifier" => "com.plexapp.plugins.library",
			"rating" => value,
			"ratedAt" => ratedAt,
		};
		d_action = PLEX_RATE;
		do_();
	}

	function on_do_rate(response) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		d_action = null;
		d_callback.invoke(response);
	}
	
	/**
	 * getAllPlaylists
	 *
	 * returns array of all playlists available for Ampache user
	 */
	function getAllPlaylists(callback) {
		d_callback = callback;

		// create empty array as initial response
		d_response = [];
		d_params = { "playlistType" => "audio" };   // only audio playlists

		// set range parameters
		d_limit = MAX_LIMIT;
        d_offset = OFFSET;
		d_count = MAX_COUNT;

		d_action = PLEX_PLAYLISTS;
		do_();
	}

	function on_do_playlists(response) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		
		// get the array of playlists
		response = response["Metadata"];
		if (!(response instanceof Lang.Array)) {
			response = [];
		}

		// append the standard playlist objects to the array
		for (var idx = 0; idx < response.size(); ++idx) {
			var playlist = response[idx];
			d_response.add(plex_to_playlist(playlist));
		}
		checkDone(response);
	}

	/**
	 * getPlaylist
	 *
	 * returns an array of one playlist object for id
	 */
	function getPlaylist(id, callback) {
		d_callback = callback;

		// create empty array as initial response
		d_response = [];
		d_count = 1;		// expect only 1 object

		d_params = {};
        d_id = PlexSource.raw(id);
		d_collectionType = collectionType(id);

		if ((d_collectionType != null)
			&& (d_collectionType.equals("mix") || d_collectionType.equals("genre"))) {
			d_action = PLEX_DYNAMIC_METADATA;
		} else {
			d_action = (d_collectionType == null)
				? PLEX_PLAYLIST : PLEX_LIBRARY_METADATA;
		}
		do_();
	}

	function on_do_dynamic_metadata(response) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		var stored = new IPlaylist(PlexSource.qualify(d_source, d_id));
		if (stored.stored()) {
			stored.setRemote(true);
			d_response.add(stored);
		}
		d_action = null;
		var completed = d_response;
		d_response = [];
		d_callback.invoke(completed);
	}

	function on_do_playlist(response) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		var metadata = response["Metadata"];
		if ((metadata instanceof Lang.Array) && (metadata.size() > 0)) {
			d_response.add(plex_to_playlist(metadata[0]));
		}

		d_action = null;
		d_count = MAX_COUNT;
		var completed = d_response;
		d_response = [];
		d_callback.invoke(completed);
	}

	function on_do_library_metadata(response) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		var metadata = null;
		if (response instanceof Lang.Dictionary) {
			metadata = response["Metadata"];
			// Depending on the Plex response format/parser, a single album or
			// artist can be exposed as Directory instead of Metadata.
			if (metadata == null) {
				metadata = response["Directory"];
			}
			// Also accept an already-unwrapped single library object.
			if ((metadata == null) && (response["ratingKey"] != null)) {
				metadata = response;
			}
		}
		if (metadata instanceof Lang.Dictionary) {
			d_response.add(plex_to_collection(metadata, d_collectionType));
		} else if ((metadata instanceof Lang.Array) && (metadata.size() > 0)) {
			d_response.add(plex_to_collection(metadata[0], d_collectionType));
		}

		// Some Plex versions omit the Metadata wrapper for a single library
		// object. We already persisted the object selected in Browse, so use it
		// to continue into /children or /allLeaves instead of falsely completing
		// the selection as an empty successful sync.
		if (d_response.size() == 0) {
			var storedCollection = new IPlaylist(PlexSource.qualify(d_source, d_id));
			if (storedCollection.stored() && storedCollection.remote()) {
				d_response.add(storedCollection);
				Plexit.Utils.log("Plex metadata wrapper missing; using stored collection " + d_id);
			}
		}
		d_action = null;
		d_count = MAX_COUNT;
		var completed = d_response;
		d_response = [];
		d_callback.invoke(completed);
	}

	function plex_to_playlist(playlist) {
		var items = playlist["leafCount"];
		if (items == null) {
			items = 0;
		}
		return new Playlist({
			"id" => PlexSource.qualify(d_source, playlist["ratingKey"]),
			"name" => playlist["title"],
			"songCount" => items.toNumber(),
			"remote" => true,
		});
	}

	function getAllAlbums(callback) {
		getAllCollections("album", callback);
	}

	function getAllArtists(callback) {
		getAllCollections("artist", callback);
	}

	function getAllGenres(callback) {
		d_callback = callback;
		d_collectionType = "genre";
		d_response = [];
		d_sectionIds = [];
		d_sectionIndex = 0;
		d_params = {};
		d_action = PLEX_LIBRARY_GENRES;
		d_api.library_sections(self.method(:on_do_library_sections), d_params);
	}

	function getAllPlexCollections(callback) {
		d_callback = callback;
		d_collectionType = "collection";
		d_response = [];
		d_sectionIds = [];
		d_sectionIndex = 0;
		d_params = {};
		d_action = PLEX_LIBRARY_COLLECTIONS;
		d_api.library_sections(self.method(:on_do_library_sections), d_params);
	}

	function getAllCollections(type, callback) {
		d_callback = callback;
		d_collectionType = type;
		d_response = [];
		d_sectionIds = [];
		d_sectionIndex = 0;
		// A previous large response may have reduced the adaptive page size all
		// the way to one. Every new browse operation must start with a clean
		// paging state, otherwise one unusually large artist cannot be retried.
		d_limit = MAX_LIMIT;
		d_offset = OFFSET;
		d_count = MAX_COUNT;
		d_params = {};
		d_action = PLEX_LIBRARY_SECTIONS;
		d_api.library_sections(self.method(:on_do_library_sections), d_params);
	}

	function on_do_library_sections(response) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		var directories = response["Directory"];
		if (directories instanceof Lang.Dictionary) { directories = [ directories ]; }
		if (directories instanceof Lang.Array) {
			for (var idx = 0; idx < directories.size(); ++idx) {
				var directory = directories[idx];
				if ((directory instanceof Lang.Dictionary)
					&& (directory["type"] instanceof Lang.String)
					&& directory["type"].equals("artist")) {
					d_sectionIds.add(directory["key"]);
				}
			}
		}
		if (d_sectionIds.size() == 0) {
			d_action = null;
			var completed = d_response;
			d_response = [];
			d_callback.invoke(completed);
			return;
		}
		if (d_action == PLEX_LIBRARY_GENRES) {
			requestGenres();
			return;
		}
		if (d_action == PLEX_LIBRARY_COLLECTIONS) {
			d_limit = MAX_LIMIT;
			d_offset = OFFSET;
			requestCollections();
			return;
		}
		d_offset = OFFSET;
		d_action = PLEX_LIBRARY_ITEMS;
		requestLibraryItems();
	}

	function requestGenres() {
		d_api.library_section_genres(
			self.method(:on_do_genres),
			{ "type" => 10 },
			d_sectionIds[d_sectionIndex]
		);
	}

	function on_do_genres(response) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		var directories = response["Directory"];
		if (directories instanceof Lang.Dictionary) { directories = [ directories ]; }
		if (directories instanceof Lang.Array) {
			for (var idx = 0; idx < directories.size(); ++idx) {
				var genre = directories[idx];
				d_response.add(new Playlist({
					"id" => PlexSource.qualify(d_source, "genre:" + d_sectionIds[d_sectionIndex] + ":" + genre["key"]),
					"name" => genre["title"],
					"songCount" => 0,
					"remote" => true,
				}));
			}
		}
		d_sectionIndex += 1;
		if (d_sectionIndex < d_sectionIds.size()) {
			requestGenres();
			return;
		}
		d_action = null;
		var completed = d_response;
		d_response = [];
		d_callback.invoke(completed);
	}

	function requestCollections() {
		d_params = {
			"sort" => "titleSort:asc",
			"X-Plex-Container-Size" => d_limit,
			"X-Plex-Container-Start" => d_offset,
		};
		d_api.library_section_collections(
			self.method(:on_do_collections),
			d_params,
			d_sectionIds[d_sectionIndex]
		);
	}

	function on_do_collections(response) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		var metadata = response["Metadata"];
		if (metadata instanceof Lang.Dictionary) { metadata = [ metadata ]; }
		if (!(metadata instanceof Lang.Array)) { metadata = []; }
		for (var idx = 0; idx < metadata.size(); ++idx) {
			d_response.add(plex_to_collection(metadata[idx], "collection"));
		}
		if (metadata.size() >= d_limit) {
			d_offset += d_limit;
			requestCollections();
			return;
		}
		d_sectionIndex += 1;
		if (d_sectionIndex < d_sectionIds.size()) {
			d_offset = OFFSET;
			requestCollections();
			return;
		}
		d_action = null;
		var completed = d_response;
		d_response = [];
		d_callback.invoke(completed);
	}

	function requestLibraryItems() {
		d_params = {
			"type" => d_collectionType.equals("album") ? 9 : 8,
			"sort" => "titleSort:asc",
			// Browse only needs top-level identifiers, titles and counts. Artist
			// records can otherwise contain enough nested metadata to exceed the
			// Connect IQ response limit even with a small page size.
			"excludeFields" => "summary,guid,thumb,art,theme,addedAt,updatedAt,index,originallyAvailableAt,contentRating,rating,viewCount,lastViewedAt,ultraBlurColors",
			"excludeElements" => "Genre,Country,Collection,Guid,Image,Similar,Location,Mood,Style",
			"X-Plex-Container-Size" => d_limit,
			"X-Plex-Container-Start" => d_offset,
		};
		d_api.library_section_all(
			self.method(:on_do_library_items),
			d_params,
			d_sectionIds[d_sectionIndex]
		);
	}

	function on_do_library_items(response) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		var metadata = response["Metadata"];
		if (metadata instanceof Lang.Dictionary) {
			metadata = [ metadata ];
		} else if (!(metadata instanceof Lang.Array)) {
			metadata = [];
		}
		for (var idx = 0; idx < metadata.size(); ++idx) {
			d_response.add(plex_to_collection(metadata[idx], d_collectionType));
		}
		if (metadata.size() >= d_limit) {
			d_offset += d_limit;
			requestLibraryItems();
			return;
		}
		d_sectionIndex += 1;
		if (d_sectionIndex < d_sectionIds.size()) {
			d_offset = OFFSET;
			requestLibraryItems();
			return;
		}
		d_action = null;
		var completed = d_response;
		d_response = [];
		d_callback.invoke(completed);
	}

	function plex_to_collection(item, type) {
		var count = item["leafCount"];
		if (count == null) {
			count = item["childCount"];
		}
		if (count == null) {
			count = 0;
		}
		var name = item["title"];
		var subtitle = type.equals("album") ? item["parentTitle"] : null;
		if (type.equals("collection")) {
			var subtype = item["subtype"];
			if (subtype instanceof Lang.String) {
				subtitle = subtype.equals("artist")
					? WatchUi.loadResource(Rez.Strings.ArtistCollection_label) : WatchUi.loadResource(Rez.Strings.AlbumCollection_label);
			} else {
				subtitle = WatchUi.loadResource(Rez.Strings.MusicCollection_label);
			}
		}
		return new Playlist({
			"id" => PlexSource.qualify(d_source, type + ":" + item["ratingKey"]),
			"name" => name,
			"subtitle" => subtitle,
			"songCount" => count.toNumber(),
			"remote" => true,
		});
	}

	function collectionType(id) {
		if (!(id instanceof Lang.String)) { return null; }
		if (id.find("album:") == 0) { return "album"; }
		if (id.find("artist:") == 0) { return "artist"; }
		if (id.find("mix:") == 0) { return "mix"; }
		if (id.find("genre:") == 0) { return "genre"; }
		if (id.find("collection:") == 0) { return "collection"; }
		return null;
	}

	function collectionRatingKey(id) {
		var separator = id.find(":");
		return id.substring(separator + 1, id.length());
	}

	/**
	 * getPlaylistSongs
	 * 
	 * returns an array of songs on the playlist with id
	 */
	function getPlaylistSongs(id, callback) {
		d_callback = callback;

		// create empty response
		d_response = [];

		d_params = {};
        d_id = PlexSource.raw(id);

        // set range parameters
		d_limit = MAX_LIMIT;
		d_offset = OFFSET;
		d_count = MAX_COUNT;
		d_dynamicBytes = 0;

		d_collectionType = collectionType(id);
		if ((d_collectionType != null)
			&& (d_collectionType.equals("mix") || d_collectionType.equals("genre"))) {
			d_count = Plexit.DynamicMix.trackLimit();
			d_action = PLEX_DYNAMIC_SONGS;
		} else {
			d_action = (d_collectionType == null)
				? PLEX_PLAYLIST_SONGS : PLEX_LIBRARY_SONGS;
		}
		do_();
	}

	function on_do_playlist_songs(response) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }

		// get the array of songs on the playlist
		if (response instanceof Lang.Dictionary) {
			var tracks = response["Metadata"];
			if (tracks == null) { tracks = response["Track"]; }
			response = tracks;
		} else {
			response = null;
		}
		if (response instanceof Lang.Dictionary) {
			response = [ response ];
		} else if (!(response instanceof Lang.Array)) {
			response = [];
		}

		appendSongs(response, false);
		checkDone(response);
	}

	function appendSongs(response, enforceDynamicLimit) {
		var maxBytes = Plexit.DynamicMix.sizeLimitMb() * 1024.0 * 1024.0;
		for (var idx = 0; idx < response.size(); ++idx) {
			var song = response[idx];

			// new way of storing songs
			var time = song["duration"];
			if (time == null) {
				time = 0;
			}
			var seconds = time.toNumber() / 1000;
			var estimatedBytes = seconds * 24000.0;
			if (enforceDynamicLimit
				&& (d_response.size() > 0)
				&& ((d_dynamicBytes + estimatedBytes) > maxBytes)) {
				return false;
			}
			if (enforceDynamicLimit && (d_response.size() >= d_count)) {
				return false;
			}

			var container = null;
			var mediaKey = null;
            var sourceBytes = null;
			var media = song["Media"];
			if ((media instanceof Lang.Array) && (media.size() > 0)) {
				var parts = media[0]["Part"];
				if ((parts instanceof Lang.Array) && (parts.size() > 0)) {
					container = parts[0]["container"];
					mediaKey = parts[0]["key"];
                    sourceBytes = parts[0]["size"];
				}
			}
			d_response.add(new Song({
				"id" => PlexSource.qualify(d_source, song["ratingKey"]),
				"title" => song["title"],
				"artist" => song["grandparentTitle"],
				"time" => seconds,
				"mime" => containerToMime(container),
				"media_key" => mediaKey,
                "sourceBytes" => sourceBytes,
					// Track.thumb is the album cover. Track.art is a much larger
					// artist/background image and is unsuitable for the watch player.
					"art_id" => PlexSource.qualify(d_source, song["thumb"]),
			}));
			d_dynamicBytes += estimatedBytes;
		}
		return true;
	}

	function dynamicParams() {
		var params = { "type" => 10 };
		if (d_collectionType.equals("genre")) {
			var genreParts = d_id.substring(6, d_id.length());
			var lastSeparator = genreParts.find(":");
			params.put("genre", genreParts.substring(lastSeparator + 1, genreParts.length()));
			params.put("sort", "titleSort");
		} else if (d_id.equals("mix:recent-added")) {
			params.put("sort", "addedAt:desc");
		} else if (d_id.equals("mix:recent-played")) {
			params.put("sort", "lastViewedAt:desc");
			params.put("viewCount>=", 1);
		} else if (d_id.equals("mix:most-played")) {
			params.put("sort", "viewCount:desc");
			params.put("viewCount>=", 1);
		} else if (d_id.equals("mix:unplayed")) {
			params.put("unwatched", 1);
			params.put("sort", "addedAt:desc");
		} else {
			params.put("userRating>=", 8);
			params.put("sort", "userRating:desc,titleSort");
		}
		params.put("X-Plex-Container-Size", d_limit);
		params.put("X-Plex-Container-Start", d_offset);
		return params;
	}

	function on_do_dynamic_sections(response) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		d_sectionIds = [];
		if (d_collectionType.equals("genre")) {
			var genreParts = d_id.substring(6, d_id.length());
			var separator = genreParts.find(":");
			d_sectionIds.add(genreParts.substring(0, separator));
		}
		var directories = response["Directory"];
		if (directories instanceof Lang.Dictionary) { directories = [ directories ]; }
		if ((d_sectionIds.size() == 0) && (directories instanceof Lang.Array)) {
			for (var idx = 0; idx < directories.size(); ++idx) {
				if ((directories[idx]["type"] instanceof Lang.String)
					&& directories[idx]["type"].equals("artist")) {
					d_sectionIds.add(directories[idx]["key"]);
				}
			}
		}
		d_sectionIndex = 0;
		d_offset = OFFSET;
		if (d_sectionIds.size() == 0) {
			completeDynamicSongs();
			return;
		}
		requestDynamicItems();
	}

	function requestDynamicItems() {
		d_api.library_section_all(
			self.method(:on_do_dynamic_items),
			dynamicParams(),
			d_sectionIds[d_sectionIndex]
		);
	}

	function on_do_dynamic_items(response) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		var tracks = response["Metadata"];
		if (tracks instanceof Lang.Dictionary) { tracks = [ tracks ]; }
		if (!(tracks instanceof Lang.Array)) { tracks = []; }
		var acceptedAll = appendSongs(tracks, true);
		if (!acceptedAll || (d_response.size() >= d_count)) {
			completeDynamicSongs();
			return;
		}
		if (tracks.size() >= d_limit) {
			d_offset += d_limit;
			requestDynamicItems();
			return;
		}
		d_sectionIndex += 1;
		if (d_sectionIndex < d_sectionIds.size()) {
			d_offset = OFFSET;
			requestDynamicItems();
			return;
		}
		completeDynamicSongs();
	}

	function completeDynamicSongs() {
		d_action = null;
		var completed = d_response;
		d_response = [];
		d_callback.invoke(completed);
	}

	/**
	 * getRefId
	 *
	 *  returns a refId for a song by id (this downloads the song)
	 */	
	function getRefId(id, mime, mediaKey, type, callback) {
		d_callback = callback;
		d_id = PlexSource.raw(id);
		d_mediaKey = mediaKey;
        d_trackSeconds = (new ISong(id)).time();
        d_api.setDownloadEstimate(null);

		// Preserve an existing MP3 without a lossy re-encode. Any failure is
		// retried through the deterministic Plex transcode path below.
		d_directStream = isDirectMp3(mime, mediaKey);
		if (d_directStream) {
            d_api.setDownloadEstimate((new ISong(id)).sourceBytes());
			d_params = { "download" => 1 };
			d_action = PLEX_STREAM;
		} else {
			prepareMp3Transcode();
			d_action = PLEX_TRANSCODE_DECISION;
		}
		do_();
	}

	function isDirectMp3(mime, mediaKey) {
		return (mime instanceof Lang.String)
			&& mime.equals("audio/mpeg")
			&& (mediaKey instanceof Lang.String)
			&& !mediaKey.equals("");
	}

	function prepareMp3Transcode() {
        d_api.setDownloadEstimate(d_trackSeconds * 192000.0 / 8);
		d_directStream = false;
		var sessionId = PlexAccount.clientId();
		d_params = {
			"path" => "/library/metadata/" + d_id,
			"session" => sessionId,
			"X-Plex-Session-Identifier" => sessionId,
			"protocol" => "http",
			"hasMDE" => 1,
			"mediaIndex" => 0,
			"partIndex" => 0,
			"directPlay" => 0,
			"directStream" => 1,
			"directStreamAudio" => 1,
			"maxAudioBitrate" => 192,
			"musicBitrate" => 192,
			"audioBitrate" => 192,
			"X-Plex-Client-Profile-Extra" => "add-transcode-target(type=musicProfile&context=streaming&protocol=http&container=mp3&audioCodec=mp3&replace=true)"
		};
	}

	function on_do_stream(contentRef) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		d_action = null;
		d_callback.invoke(contentRef.getId(), d_api.downloadBytes());
	}

	function on_do_transcode_decision(responseCode, body) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		if (responseCode == 200) {
			d_action = PLEX_STREAM;
			do_();
			return;
		}

		var error = Plexit.HttpError.is(responseCode);
		if (error == null) {
			error = Plexit.GarminSdkError.is(responseCode);
		}
		if (error == null) {
			error = new Plexit.ApiError(Plexit.ApiError.BADRESPONSE);
		}
		d_action = null;
		d_fallback.invoke(error);
	}

	/**
	 * getArtwork
	 *
	 *  returns a BitmapResource for a song/podcast by id
	 */	
	function getArtwork(id, type, callback) {
		d_callback = callback;

		d_params = {};
		d_id = PlexSource.raw(id);

		d_action = PLEX_GET_ART;
		do_();
	}

	function on_do_get_art(artwork) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
		d_action = null; 
		d_callback.invoke(artwork);
	}

	function checkDone(response) {
		// if response less than limit, or collected count objects
		// - no more requests required
		if (d_limit == null) {
			d_limit = MAX_LIMIT;
		}

		if ((d_response.size() < d_count)		// count not reached 
			&& (response.size() >= d_limit)) {	// limit reached
			// request required, since response was full and count not reached
			d_offset += d_limit;	// increase offset
			do_();
			return;
		}
		
		// no more requests needed, reset and callback
		d_action = null;
		d_count = MAX_COUNT;		// reset to max count for next request
		var completed = d_response;
		d_response = [];
		d_callback.invoke(completed);
	}

	/*
	 * do_
	 * 
	 * dispatcher function from enum to api call
	 * assumes required params are set, can be repeated
	 */
	function do_() {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
        if (!d_api.isAvailable()) {
            onError(new Plexit.ApiError(Plexit.ApiError.ACCESS));
            return;
        }
		
		// ping does not need authentication
		if (d_action == PLEX_PING) {
			d_api.identity(self.method(:on_do_ping));
			return;
		}
		if (d_action == PLEX_RECORD_PLAY) {
			d_api.scrobble(self.method(:on_do_record_play), d_params);
			return;
		}
		if (d_action == PLEX_RATE) {
			d_api.rate(self.method(:on_do_rate), d_params);
			return;
		}
		if (d_action == PLEX_TRANSCODE_DECISION) {
			d_api.music_transcode_decision(self.method(:on_do_transcode_decision), d_params);
			return;
		}
		if (d_action == PLEX_STREAM) {
			if (d_directStream) {
				d_api.stream(self.method(:on_do_stream), d_params, d_mediaKey, Media.ENCODING_MP3);
			} else {
				d_api.music_transcode(self.method(:on_do_stream), d_params, Media.ENCODING_MP3);
			}
			return;
		}
		if (d_action == PLEX_GET_ART) {
			d_api.photo_transcode(self.method(:on_do_get_art), d_params, d_id);
			return;
		}
		if (d_action == PLEX_LIBRARY_SECTIONS) {
			d_api.library_sections(self.method(:on_do_library_sections), d_params);
			return;
		}
		if (d_action == PLEX_LIBRARY_ITEMS) {
			requestLibraryItems();
			return;
		}
		if (d_action == PLEX_LIBRARY_GENRES) {
			requestGenres();
			return;
		}
		if (d_action == PLEX_LIBRARY_COLLECTIONS) {
			requestCollections();
			return;
		}
		if (d_action == PLEX_DYNAMIC_METADATA) {
			d_api.library_sections(self.method(:on_do_dynamic_metadata), d_params);
			return;
		}
		if (d_action == PLEX_DYNAMIC_SONGS) {
			d_api.library_sections(self.method(:on_do_dynamic_sections), {});
			return;
		}
		// if (d_action == PLEX_PODCAST) {
		// 	d_api.podcast(self.method(:on_do_podcasts), d_params);
		// 	return;
		// }

        // following requests are ranged requests, limit and offset should be provided
        d_params.put("X-Plex-Container-Size", d_limit);
        d_params.put("X-Plex-Container-Start", d_offset);

		if (d_action == PLEX_PLAYLIST) {
			d_api.playlist(self.method(:on_do_playlist), d_params, d_id);
			return;
		}
		if (d_action == PLEX_LIBRARY_METADATA) {
			d_api.metadata(
				self.method(:on_do_library_metadata),
				d_params,
				collectionRatingKey(d_id)
			);
			return;
		}
		if (d_action == PLEX_PLAYLISTS) {
			d_api.playlists(self.method(:on_do_playlists), d_params);
			return;
		}
		if (d_action == PLEX_PLAYLIST_SONGS) {
			d_api.playlists_items(self.method(:on_do_playlist_songs), d_params, d_id);
			return;
		}
		if (d_action == PLEX_LIBRARY_SONGS) {
			var ratingKey = collectionRatingKey(d_id);
			if (d_collectionType.equals("album")) {
				d_api.metadata_children(
					self.method(:on_do_playlist_songs),
					d_params,
					ratingKey
				);
			} else {
				d_api.metadata_all_leaves(
					self.method(:on_do_playlist_songs),
					d_params,
					ratingKey
				);
			}
			return;
		}
		// if (d_action == PLEX_PODCASTS) {
		// 	d_api.podcasts(self.method(:on_do_podcasts), d_params);
		// 	return;
		// }
		// if (d_action == PLEX_EPISODES) {
		// 	d_api.podcast_episodes(self.method(:on_do_episodes), d_params);
		// 	return;
		// }

		// no valid action defined
	}

	function onError(error) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
        if ((error instanceof Plexit.GarminSdkError)
            && ((error.respCode() == Communications.REQUEST_CANCELLED)
                || (error.respCode() == Communications.BLE_REQUEST_CANCELLED))) {
            d_action = null;
            d_fallback.invoke(error);
            return;
        }
		// A file reported as MP3 can still be unsuitable for the watch or the
		// direct Part URL can fail. Transparently retry it as MP3/192 kbps once.
		if ((d_action == PLEX_STREAM) && d_directStream) {
			prepareMp3Transcode();
			d_action = PLEX_TRANSCODE_DECISION;
			do_();
			return;
		}

        // if response too large and limit is possible
		if ((error instanceof Plexit.GarminSdkError)
			&& PlexServerRequest.isResponseTooBig(error.respCode())
			&& (d_limit > 1)) {
			
			d_limit = (d_limit / 2).toNumber();		// half the response
			Plexit.Utils.log("Plex response too large; retrying with page size " + d_limit);
			do_();									// retry the request
			return;
		}

		d_action = null;
		Plexit.Utils.log("Plex request failed: " + error);
		d_fallback.invoke(error);
    }

    function onProgress(progress) {
        if (!PlexSyncSession.valid(d_syncSession)) { return; }
        d_progress.invoke(progress);
    }   
    
    function setFallback(fallback) {
    	d_fallback = fallback;
    }

	function setProgressCallback(progress) {
		d_progress = progress;
	}

	function containerToMime(container) {
		var map = {
			"mp3" => "audio/mpeg",
			"mp4" => "audio/mp4",
			"wav" => "audio/wav",
		};
		if (!(container instanceof Lang.String)) {
			container = "mp3";
		}
		return map[container];
	}
}
