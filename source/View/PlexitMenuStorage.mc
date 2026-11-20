using Toybox.WatchUi;
using Toybox.Communications;
using Toybox.Application;
using Toybox.Lang;
using Plexit.Menu;

module Plexit {
	module Menu {
		class Storage extends MenuBase {

			function initialize() {
				MenuBase.initialize(WatchUi.loadResource(Rez.Strings.Storage_label), false);
			}

			function load() {
				return MenuBase.load([
					{
						LABEL => WatchUi.loadResource(Rez.Strings.StorageInfo_label),
						SUBLABEL => method(:sublabel_Cache),
						METHOD => method(:onInfo),
					},
					new Menu.Downloads(),
					{
						LABEL => WatchUi.loadResource(Rez.Strings.confSync_MoreInfo_RemoveAll_label), 
						SUBLABEL => WatchUi.loadResource(Rez.Strings.confSync_MoreInfo_RemoveAll_sublabel),
						METHOD => method(:onRemoveAll),
					}
				]);
			}

			static function onInfo() {
				var cache = Media.getCacheStatistics();
				var songCount = 0;
				var songIds = SongStore.getIds();
				for (var idx = 0; idx < songIds.size(); ++idx) {
					if (SongStore.isCached(songIds[idx])) {
						songCount += 1;
					}
				}

				var playlistCount = 0;
				var playlistIds = PlaylistStore.getIds();
				for (var idx = 0; idx < playlistIds.size(); ++idx) {
					if ((new IPlaylist(playlistIds[idx])).local()) {
						playlistCount += 1;
					}
				}

				var free = cache.capacity - cache.size;
				var message = WatchUi.loadResource(Rez.Strings.Downloaded_label) + "\n" + formatBytes(cache.size)
					+ "\n\n" + WatchUi.loadResource(Rez.Strings.Free_label) + "\n" + formatBytes(free)
					+ "\n\n" + WatchUi.loadResource(Rez.Strings.Songs_label) + "  " + songCount
					+ "\n" + WatchUi.loadResource(Rez.Strings.Playlists_label) + "  " + playlistCount;
				WatchUi.pushView(new TextView(message), new WatchUi.BehaviorDelegate(), WatchUi.SLIDE_IMMEDIATE);
			}

			static function sublabel_Memory() as Lang.String {
				var stats = System.getSystemStats();
				return formatBytes(stats.usedMemory) + " / " + formatBytes(stats.totalMemory);
			}

			static function sublabel_Cache() as Lang.String {
				var stats = Media.getCacheStatistics();
				return formatBytes(stats.size) + " / " + formatBytes(stats.capacity);
			}

			static function onDonate() {
				WatchUi.pushView(new DonateView(), new DonateDelegate(), WatchUi.SLIDE_IMMEDIATE);
			}
			
			static function onRemoveAll() {
				var msg = WatchUi.loadResource(Rez.Strings.DeleteAllConfirmation);
				WatchUi.pushView(new WatchUi.Confirmation(msg), new PlexitConfirmationDelegate(self.method(:removeAll)), WatchUi.SLIDE_IMMEDIATE);
			}
			
			static function removeAll() {
				// collect all ids of songs
				// var ids = SongStore.getIds();
				// for (var idx = 0; idx != ids.size(); ++idx) {
				// 	var id = ids[idx];
				// 	var isong = new ISong(id);
				// 	isong.remove();					// remove from Store
				// }
				// ids = ArtworkStore.getIds();
				// for (var idx = 0; idx < ids.size(); ++idx) {
				// 	var id = ids[idx];
				// 	var iartwork = new IArtwork(id);
				// 	iartwork.remove();				// remove from Storage
				// }

				// remove all cached media
				Media.resetContentCache();
				
				// remove all metadata
				Application.Storage.clearValues();

				// Store modules mirror Application.Storage in RAM. Clearing only the
				// persistent values leaves stale playlists/song counts visible until a
				// full process restart (which the simulator does not always perform).
				SongStore.reset();
				PlaylistStore.reset();
				ArtworkStore.reset();
				Plexit.ScrobbleStore.reset();
				Plexit.RatingStore.reset();
				Plexit.PlayableStore.reset();
				Plexit.Provider.onSettingsChanged();
				
				// check storage to set the storage version number
				Plexit.Storage.check();

				// exit app to make sure ram is cleared
				System.exit();
			}

			static function formatBytes(bytes as Lang.Integer) as Lang.String {
				if (bytes == 0) {
					return "0 " + WatchUi.loadResource(Rez.Strings.BytesUnit);
				}
				var k = 1024;
				var sizes = [WatchUi.loadResource(Rez.Strings.BytesUnit), "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"];
				var in = Math.floor(Math.log(bytes, 10) / Math.log(k, 10));
				var flt = (bytes / Math.pow(k, in));
				return flt.format("%.1f") + " " + sizes[in.toNumber()];
			}
		}

		class Downloads extends MenuBase {

			function initialize() {
				MenuBase.initialize(WatchUi.loadResource(Rez.Strings.Downloads_label), false);
			}

			function load() {
				// Menu entries are generated dynamically in getItem(). MenuView calls
				// it again whenever the Downloads screen is shown, so a deleted album
				// disappears immediately instead of surviving as a cached 0-song row.
				return MenuBase.load([]);
			}

			function getItem(itemIndex) {
				var localIndex = 0;
				var ids = PlaylistStore.getIds();
				for (var idx = 0; idx < ids.size(); ++idx) {
					var playlist = new IPlaylist(ids[idx]);
					if (playlist.local()) {
						if (localIndex == itemIndex) {
							var settings = new Menu.DownloadSettings(playlist);
							return new WatchUi.MenuItem(
								settings.label(),
								settings.sublabel(),
								settings.get(METHOD),
								null
							);
						}
						localIndex += 1;
					}
				}
				return null;
			}
		}

		class DownloadSettings extends MenuBase {
			private var d_downloadId;

			function initialize(playlist) {
				MenuBase.initialize(playlist.name(), false);
				d_downloadId = playlist.id();
			}

			function sublabel() {
				var playlist = new IPlaylist(d_downloadId);
				return downloadSummary(playlist);
			}

			function downloadSummary(playlist) {
				var downloaded = 0;
				var bytes = 0.0;
				var estimated = false;
				var songIds = playlist.songs();
				for (var idx = 0; idx < songIds.size(); ++idx) {
					var song = new ISong(songIds[idx]);
					if (song.refId() != null) {
						downloaded += 1;
						var size = song.downloadBytes();
						if (size != null && size > 0) {
							bytes += size;
						} else {
							// Legacy downloads and responses without Content-Length.
							// Single-track collections may have older, stale song duration.
							var seconds = (songIds.size() == 1) ? playlist.time() : song.time();
							bytes += seconds * 24000.0;
							estimated = true;
						}
					}
				}

				var megabytes = bytes / (1024.0 * 1024.0);
				var prefix = estimated ? "~" : "";
				var count = (downloaded < songIds.size())
					? downloaded.toString() + "/" + Plexit.I18n.songs(songIds.size())
					: Plexit.I18n.songs(downloaded);
				return count + " / " + prefix + megabytes.format("%.1f") + " MB";
			}

			function load() {
				var playlist = new IPlaylist(d_downloadId);
				return MenuBase.load([
					{
						LABEL => WatchUi.loadResource(Rez.Strings.StorageInfo_label),
						SUBLABEL => downloadSummary(playlist),
						METHOD => method(:onInfo),
					},
					{
						LABEL => WatchUi.loadResource(Rez.Strings.DeleteDownload_label),
						SUBLABEL => null,
						METHOD => method(:onDelete),
					},
				]);
			}

			function onInfo() {
				var playlist = new IPlaylist(d_downloadId);
				var mins = (playlist.time() / 60).toNumber();
				var message = playlist.name() + "\n\n" + downloadSummary(playlist)
					+ "\n" + Plexit.I18n.text(Rez.Strings.MinutesCount, [mins]);
				WatchUi.pushView(new TextView(message), new WatchUi.BehaviorDelegate(), WatchUi.SLIDE_IMMEDIATE);
			}

			function onDelete() {
				var playlist = new IPlaylist(d_downloadId);
				var message = Plexit.I18n.text(Rez.Strings.DeleteDownloadConfirmation, [playlist.name()]);
				WatchUi.pushView(
					new WatchUi.Confirmation(message),
					new PlexitConfirmationDelegate(method(:deleteDownload)),
					WatchUi.SLIDE_IMMEDIATE
				);
			}

			function deleteDownload() {
				var playlist = new IPlaylist(d_downloadId);
				playlist.setLocal(false);
				playlist.remove();

				// Remove files that are no longer referenced by another playlist.
				var ids = SongStore.getDeletes();
				for (var idx = 0; idx < ids.size(); ++idx) {
					(new ISong(ids[idx])).remove();
				}
				WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
			}
		}
	}
}
