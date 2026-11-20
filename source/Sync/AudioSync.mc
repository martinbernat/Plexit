class AudioSync extends Deferrable {

	private var d_provider = null;
	private var d_providerSource = null;	// server id d_provider was created for
	private var d_audio = null;		// front of the todos
	
	private var d_failed = [];		// array of all failed
	private var d_lastError = null;	// last download error reported by Garmin/Plex
	
	private var f_progress; 		// callback on progress
	
	// store sync size
	// Song ids only: an Audio object per pending song runs out of memory.
	private var d_pendingAudio = [];	// array of song ids
	private var d_pendingTotal;		// the number of items that had to be synced

	function initialize(progress, done, fail) {
		Deferrable.initialize(method(:sync), done, fail);		// make sync the deferred task
		
		f_progress = progress;

		// first delete the todeletes
		var ids = SongStore.getDeletes();
		for (var idx = 0; idx < ids.size(); ++idx) {
			var id = ids[idx];
			var isong = new ISong(id);
			isong.remove();					// remove from Store
		}
		
		// now get songs that have not yet been downloaded
		ids = SongStore.getIds();
		for (var idx = 0; idx != ids.size(); ++idx) {
				var song = SongStore.get(ids[idx]);

				// only add to todo if not yet stored
				if ((song == null) || (song["refId"] == null)) {
					d_pendingAudio.add(ids[idx]);
				}
		}
		d_pendingTotal = d_pendingAudio.size();
	}
	
	function sync() {
        if (!isActive()) { return false; }
		// if songs all finished, complete this task
		if (d_pendingAudio.size() == 0) {
			if (d_failed.size() > 0) {
				Plexit.Utils.log("Audio sync failed for " + d_failed.size() + " song(s): " + d_lastError);
				return Deferrable.complete();
			}
	   		return Deferrable.complete();				// set complete
		}

		// update progress
		f_progress.invoke(progress());
		
		// Skip this source for the rest of this sync after its connection failed.
        var source = PlexSource.serverId(d_pendingAudio[0]);
        if (PlexServers.skipSync(source)) {
            onError(new Plexit.ApiError(Plexit.ApiError.ACCESS));
            return Deferrable.defer();
        }
        d_audio = new Audio(d_pendingAudio[0], Audio.SONG);
        // A provider is never freed (its request callbacks form a reference
        // cycle), so one per song runs out of memory during long syncs.
        if ((d_provider == null) || !PlexSource.sameServer(d_providerSource, source)) {
            d_provider = Plexit.Provider.forItem(d_audio.id());
            d_providerSource = source;
            d_provider.setFallback(method(:onError));
            d_provider.setProgressCallback(method(:onProgress));
        }
        // start download
		d_provider.getRefId(
			d_audio.id(),
			d_audio.mime(),
			d_audio.mediaKey(),
			d_audio.type(),
			method(:onDownloaded)
		);
		return Deferrable.defer();
	}

	function progress() {
		// determine what is left to do
		var todo = 0;
		if (d_pendingAudio != null) { todo = d_pendingAudio.size(); }
		
		var done = d_pendingTotal - todo;
		var progress = (100 * done) / d_pendingTotal.toFloat();
		return progress;
	}

	// handle callback on intermediate progress
	function onProgress(progress) {
        if (!isActive()) { return; }
		progress /= d_pendingTotal.toFloat();
		f_progress.invoke(progress() + progress);
	}
	
    // Callback for when a song is downloaded
	function onDownloaded(refId, downloadBytes) {
        if (!isActive()) { return; }
		if (refId == null) {
			onError(new Plexit.ApiError(Plexit.ApiError.BADRESPONSE));
			return;
		}

		// update refId
		var downloadedId = d_audio.id();
		if (!d_audio.setRefId(refId)) {
			onError(new Plexit.ApiError(Plexit.ApiError.BADRESPONSE));
			return;
		}
		var storedSong = new ISong(downloadedId);
		storedSong.setDownloadBytes(downloadBytes);
		Plexit.Utils.log("Audio cached successfully: " + downloadedId
			+ ", refId=" + storedSong.refId()
			+ ", pending=" + SongStore.getTodos().size());

		// continue to next song
		d_pendingAudio.removeAll(d_pendingAudio[0]);
	
		sync();
	}
    
	function onError(error) {
        if (!isActive()) { return; }
        if ((error instanceof Plexit.GarminSdkError)
            && ((error.respCode() == Toybox.Communications.REQUEST_CANCELLED)
                || (error.respCode() == Toybox.Communications.BLE_REQUEST_CANCELLED))) {
            Deferrable.cancel(error);
            return;
        }
		// check if song in progress
		if ((d_pendingAudio.size() == 0) || (d_pendingAudio[0] == null)) {
			Deferrable.cancel(error);
			return;
		}

		// indicate failed sync
//   	d_playlist.setError(error); TODO
		d_failed.add(d_pendingAudio[0]);
		d_lastError = error;
		// record the cause of failure
//		d_pendingAudio[0].setError(error);				TODO
		
		// remove first element from todo list
		d_pendingAudio.removeAll(d_pendingAudio[0]);

		sync();
		return;
	}
}
