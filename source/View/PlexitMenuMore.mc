using Toybox.WatchUi;
using Toybox.Communications;
using Toybox.Application;
using Toybox.Lang;
using Toybox.Time;
using Plexit.Storage;

module Plexit {
	module Menu {
		class AddMusic extends MenuBase {
            function getItem(idx) { if (idx == 0) { load(); } return MenuBase.getItem(idx); }

			function initialize() {
				MenuBase.initialize(WatchUi.loadResource(Rez.Strings.AddMusic_label), false);
			}

			function load() {
				var items = [
					{
						LABEL => method(:getSyncLabel),
						SUBLABEL => method(:getSyncStatus),
						METHOD => method(:onStartSync),
					},
                ];
                items.addAll([
					new Menu.PlaylistsRemoteToggle(WatchUi.loadResource(Rez.Strings.Playlists_label), null),
					new Menu.PlaylistsRemoteToggle(WatchUi.loadResource(Rez.Strings.Albums_label), "album"),
					new Menu.PlaylistsRemoteToggle(WatchUi.loadResource(Rez.Strings.Artists_label), "artist"),
					new Menu.PlaylistsRemoteToggle(WatchUi.loadResource(Rez.Strings.Collections_label), "collection"),
					new Menu.DynamicMixes(),
				]);
                return MenuBase.load(items);
			}

			function sublabel() {
				return getSyncStatus();
			}

			static function getSyncLabel() {
				if (!PlexAccount.isConnected()) {
					return WatchUi.loadResource(Rez.Strings.PlexNotConnected);
				}
				if (hasPendingChanges()) {
					return WatchUi.loadResource(Rez.Strings.SyncPending_label);
				}
				return WatchUi.loadResource(Rez.Strings.SyncNow_label);
			}

			static function getSyncStatus() {
				if (!PlexAccount.isConnected()) {
					return WatchUi.loadResource(Rez.Strings.PlexSignInHint);
				}
				var pending = getPendingSummary();
				if (pending != null) {
					return pending;
				}
				return getLastSyncString();
			}

			static function getPendingSummary() {
				if (!PlexAccount.isConnected()) {
					return null;
				}
				RatingStore.reload();
                var sources = new PlexServers.SourceFilter();
                var pendingRatings = 0;
                var ratingIds = RatingStore.getIds();
                for (var ratingIdx = 0; ratingIdx < ratingIds.size(); ratingIdx += 1) {
                    if (sources.isEnabled(ratingIds[ratingIdx])) { pendingRatings += 1; }
                }
				// A child browse menu can persist a selection from a different
				// native view context. Always read the latest persisted selection.
				PlaylistStore.reload();
				var songs = 0;
				var changes = false;
				var selections = 0;
				var ids = PlaylistStore.getIds();
				for (var idx = 0; idx < ids.size(); ++idx) {
					var playlist = new IPlaylist(ids[idx]);
                    if (playlist.local() && !sources.isEnabled(playlist.id())) { continue; }
					if (playlist.local() && !playlist.synced()) {
						songs += playlist.count();
						selections += 1;
						changes = true;
					} else if (!playlist.local() && playlist.linked()) {
						changes = true;
					}
				}

				// Before playlist metadata is fetched, playlist.count() is the best
				// estimate. During/after a partial sync, the todo store is exact.
                var todoIds = SongStore.getTodos();
                var todoSongs = 0;
                for (var todoIdx = 0; todoIdx < todoIds.size(); todoIdx += 1) {
                    if (sources.isEnabled(todoIds[todoIdx])) { todoSongs += 1; }
                }
				if (todoSongs > songs) {
					songs = todoSongs;
				}
				if (songs > 0) {
					return Plexit.I18n.songsWaiting(songs);
				}
				if (selections > 0) {
					return Plexit.I18n.selectionsWaiting(selections);
				}
				if (changes || (SongStore.getDeletes().size() > 0)) {
					return WatchUi.loadResource(Rez.Strings.SyncChangesWaiting);
				}
				if (pendingRatings > 0) {
					return Plexit.I18n.ratingsWaiting(pendingRatings);
				}
				return null;
			}

			static function hasPendingChanges() {
				return getPendingSummary() != null;
			}
			
			static function getLastSyncString() {
				var lastsync = Application.Storage.getValue(Storage.LAST_SYNC);
		        var sublabel = null;
		        if ((lastsync != null) && (lastsync["time"] instanceof Lang.Number)) {
		        	var moment = new Time.Moment(lastsync["time"]);
			        var info = Time.Gregorian.info(moment, Time.FORMAT_MEDIUM);
			        sublabel = Lang.format("$1$ $2$ $3$ - $4$:$5$", [ info.day, info.month, info.year, info.hour, info.min.format("%02d") ]);
	        	}
	        	return sublabel;
			}
			
				static function onStartSync() {
					if (!PlexAccount.isConnected()) {
						WatchUi.pushView(new PlexLoginView(), new WatchUi.BehaviorDelegate(), WatchUi.SLIDE_IMMEDIATE);
						return;
					}
				// store sync request, refer to bug https://forums.garmin.com/developer/connect-iq/i/bug-reports/bug-media-communications-syncdelegate-blocks-charging
				Application.Storage.setValue(Storage.SYNC_REQUEST, true);
				// var syncrequest  = Application.Storage.getValue(Storage.SYNC_REQUEST);
				
					// The following screen belongs to Garmin, so only its initial message
					// can be customized. Progress remains controlled by notifySyncProgress.
					if (Communications has :startSync2) {
						Communications.startSync2({
							:message => WatchUi.loadResource(Rez.Strings.SyncingMusicMessage),
						});
					} else {
						Communications.startSync();
					}
				}
			
		}
	}
}
