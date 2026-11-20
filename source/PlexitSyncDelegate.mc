using Toybox.Application;
using Toybox.Communications;
using Toybox.Media;
using Toybox.Time;
using Toybox.WatchUi;
using Plexit.Storage;

module Plexit {
	
	// Performs the sync with the music provider
	class Syncer {

		// progress callbacks are variable due to Media/Communications bug
		private var d_notifySyncProgress;
		private var d_notifySyncComplete;

		// playlists to sync
		private var d_ids;
		private var d_ids_total = 0;	// nr of ids in beginning
		private var d_last = 0;			// last idx
		private var d_running = false;
        private var d_session = null;
		private var d_lastProgress = 0;		// progress shown by the native sync UI

		enum { START, RATINGS = START, SCROBBLE, PLAYLISTS, AUDIO, ARTWORK, END}
		private var d_syncstage = START;	// track the stage for sync process

		function initialize(notifySyncProgress, notifySyncComplete) {
			d_notifySyncProgress = notifySyncProgress;
			d_notifySyncComplete = notifySyncComplete;
		}

		// Starts the sync with the system
		function onStartSync() {
            d_session = PlexSyncSession.begin();
            d_running = true;
            PlexServers.beginSync();
			// Garmin can keep the sync delegate in a separate long-lived runtime
			// context. Offline selections made in the configuration views are
			// already persisted, but this context may still hold the PlaylistStore
			// snapshot from app startup. Refresh before d_ids is constructed.
			PlaylistStore.reload();
			PlaylistStore.debugState("sync-start");
			d_syncstage = START;
			d_lastProgress = 0;
			// show progress
			reportProgress(0);
			
			// Push offline ratings and playback history before refreshing dynamic
			// playlists such as Favorites and Recently Played.
			doSync();
		}

		// stops the sync
		function onStopSync() {
            if (!d_running || !PlexSyncSession.valid(d_session)) { return; }
            d_running = false;
            PlexSyncSession.stop();
			Communications.cancelAllRequests();

			var errorMessage = WatchUi.loadResource(Rez.Strings.SyncStopped);
			d_notifySyncComplete.invoke(errorMessage);
		}

		function onCompleteSync() {
            if (!d_running || !PlexSyncSession.valid(d_session)) { return; }
			var songIds = SongStore.getIds();
			var cachedSongs = 0;
			for (var idx = 0; idx < songIds.size(); ++idx) {
				var song = new ISong(songIds[idx]);
				if (song.refId() != null) { cachedSongs += 1; }
			}
			Plexit.Utils.log("Sync verification: cached=" + cachedSongs
				+ ", songs=" + songIds.size()
				+ ", pending=" + SongStore.getTodos().size());

			var playlistIds = PlaylistStore.getIds();
			for (var playlistIdx = 0; playlistIdx < playlistIds.size(); ++playlistIdx) {
				var playlist = new IPlaylist(playlistIds[playlistIdx]);
                if (playlist.local()) { playlist.refreshSyncState(); }
				Plexit.Utils.log("Playlist verification: id=" + playlist.id()
					+ ", local=" + playlist.local()
					+ ", synced=" + playlist.synced()
					+ ", songs=" + playlist.count());
			}

			// The native Garmin player reads the persisted playable queue. On the
			// first sync it is empty, which leaves the default player on "No media"
			// until the user manually selects Play All. Preserve an existing queue,
			// but initialize an empty one from all downloaded songs.
			var playable = new Plexit.IPlayable();
			playable.removeRemoved();
			if ((playable.size() == 0) && (cachedSongs > 0)) {
				playable.loadSongIds(songIds);
				Plexit.Utils.log("Playback queue initialized with " + playable.size() + " song(s)");
			}

			reportProgress(100);
			// finish sync
            var incomplete = false;
            var sources = new PlexServers.SourceFilter();
            var pendingIds = SongStore.getTodos();
            for (var pendingIdx = 0; pendingIdx < pendingIds.size(); pendingIdx += 1) {
                if (sources.isEnabled(pendingIds[pendingIdx])) { incomplete = true; }
            }
            for (var checkIdx = 0; checkIdx < playlistIds.size(); checkIdx += 1) {
                var selection = new IPlaylist(playlistIds[checkIdx]);
                if (selection.local() && !selection.synced()
                    && sources.isEnabled(selection.id())) { incomplete = true; }
            }
			d_running = false;
            PlexSyncSession.stop();
			d_notifySyncComplete.invoke(incomplete ? WatchUi.loadResource(Rez.Strings.SyncIncompleteMessage) : null);
			Application.Storage.setValue(Storage.LAST_SYNC, { "time" => Time.now().value(), });
		}

		function doSync() {
            if (!d_running || !PlexSyncSession.valid(d_session)) { return; }
			var deferrable = getSync(d_syncstage);
			if (deferrable == null) {
				// this means no more syncs available
				onCompleteSync();
				return;
			}
			if (deferrable.run()) {
				onDone();
			}
			// if not completed, do nothing and wait for calback
		}

		function getSync(idx) {
			var progress = method(:onProgress);
			var done = method(:onDone);
			var fail = method(:onError);
			if (idx == RATINGS) {
				return new RatingSync(progress, done, fail);
			} else if (idx == SCROBBLE) {
				return new ScrobbleSync(progress, done, fail);
			} else if (idx == PLAYLISTS) {
				d_ids = PlaylistStore.getIds();
				d_ids_total = d_ids.size();
				Plexit.Utils.log("Sync queue loaded with " + d_ids_total + " selection(s)");
				for (var queueIdx = 0; queueIdx < d_ids.size(); ++queueIdx) {
					var queued = new IPlaylist(d_ids[queueIdx]);
					Plexit.Utils.log("Sync queue item: id=" + queued.id()
						+ ", local=" + queued.local()
						+ ", synced=" + queued.synced());
				}
				var step = method(:stepPlaylist);
				return new DeferredFor(0, d_ids.size(), step, done, fail);
			} else if (idx == AUDIO) {
				return new AudioSync(progress, done, fail);
			} else if (idx == ARTWORK) {
				return new ArtworkSync(progress, done, fail);
			} else if (idx == END) {
				var playable = new Plexit.IPlayable();
				playable.removeRemoved();
				return null;
			}
			return null;
		}

		function onDone() {
            if (!d_running || !PlexSyncSession.valid(d_session)) { return; }
			// Complete the current stage before starting the next one. Individual
			// sync tasks report progress relative to their own stage.
			reportStageProgress(100);
			// go to next stage
			d_syncstage += 1;
			doSync();
		}
	
		function stepPlaylist(idx, done, fail) {
			d_last = idx;
			return new PlaylistSync(d_ids[idx], method(:onPlaylistProgress), done, fail);
		}
		
		function onProgress(progress) {
            if (!d_running || !PlexSyncSession.valid(d_session)) { return; }
			reportStageProgress(progress);
		}
		
		function onPlaylistProgress(progress) {
            if (!d_running || !PlexSyncSession.valid(d_session)) { return; }
			if (d_ids_total == 0) {
				reportStageProgress(100);
				return;
			}

			// PlaylistSync reports progress for one playlist. Include the number
			// of playlists already completed so a new playlist cannot move the
			// native progress bar backwards.
			var playlistProgress = (100.0 * d_last + progress) / d_ids_total.toFloat();
			reportStageProgress(playlistProgress);
		}

		function reportStageProgress(progress) {
			if (progress < 0) { progress = 0; }
			if (progress > 100) { progress = 100; }

			// The phases do not represent equal amounts of work. Scrobbling and
			// resolving collection metadata are normally quick, while transcoding
			// and downloading audio dominates the sync. Equal 25% buckets made the
			// UI jump to 50% before the first song download began.
			var stageStart = 0;
			var stageWeight = 0;
			if (d_syncstage == RATINGS) {
				stageStart = 0;
				stageWeight = 1;
			} else if (d_syncstage == SCROBBLE) {
				stageStart = 1;
				stageWeight = 1;
			} else if (d_syncstage == PLAYLISTS) {
				stageStart = 2;
				stageWeight = 8;
			} else if (d_syncstage == AUDIO) {
				stageStart = 10;
				stageWeight = 80;
			} else if (d_syncstage == ARTWORK) {
				stageStart = 90;
				stageWeight = 10;
			} else {
				stageStart = 100;
			}

			var overall = stageStart + ((progress * stageWeight) / 100.0);
			reportProgress(overall);
		}

		function reportProgress(progress) {
            if (!d_running || !PlexSyncSession.valid(d_session)) { return; }
			var value = progress.toNumber();
			if (value < d_lastProgress) { return; }
			if (value > 100) { value = 100; }

			d_lastProgress = value;
			d_notifySyncProgress.invoke(value);
		}
		
		function onError(error) {
            if (!d_running || !PlexSyncSession.valid(d_session)) { return; }
            d_running = false;
            PlexSyncSession.stop();
            Communications.cancelAllRequests();
			// notify short error during sync
			d_notifySyncComplete.invoke(error.shortString());
		}

		// Sync always needed to verify new songs on the server
		function isSyncNeeded() {
			return true;
		}
	}

	class SyncDelegate extends Communications.SyncDelegate {

		// store generic syncer for future calls
		private var d_syncer = new Syncer(
									method(:notifySyncProgress), 
									method(:notifySyncComplete));

		function initialize() {
			SyncDelegate.initialize();
		}

		function notifySyncProgress(percentageComplete) {
			Communications.notifySyncProgress(percentageComplete);
		}

		function notifySyncComplete(errorMessage) {
			Communications.notifySyncComplete(errorMessage);
			
			// mark as no sync request pending
        	Application.Storage.setValue(Storage.SYNC_REQUEST, false);
		}

		function isSyncNeeded() {
			return d_syncer.isSyncNeeded();
		}

		function onStartSync() {
			return d_syncer.onStartSync();
		}

		function onStopSync() {
			return d_syncer.onStopSync();
		}
	}

	class SyncDelegate_deprecated extends Media.SyncDelegate {

		private var d_syncer = new Syncer(
									method(:notifySyncProgress), 
									method(:notifySyncComplete));
		
		function initialize() {
			SyncDelegate.initialize();
		}

		function notifySyncProgress(percentageComplete) {
			Media.notifySyncProgress(percentageComplete);
		}

		function notifySyncComplete(errorMessage) {
			Media.notifySyncComplete(errorMessage);
		}

		function isSyncNeeded() {
			return d_syncer.isSyncNeeded();
		}

		function onStartSync() {
			return d_syncer.onStartSync();
		}

		function onStopSync() {
			return d_syncer.onStopSync();
		}
	}
}
