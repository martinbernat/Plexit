using Toybox.Lang;
using Toybox.Application;
using Toybox.WatchUi;
using Toybox.Timer;

module Plexit {
    module Menu {
        class CollectionSearchDelegate extends WatchUi.TextPickerDelegate {
            private var d_menu;

            function initialize(menu) {
                TextPickerDelegate.initialize();
                d_menu = menu;
            }

            function onTextEntered(text, changed) {
                d_menu.setSearch(text);
                return true;
            }

            function onCancel() {
                return true;
            }
        }

        class PlaylistsRemoteToggle extends MenuBase {
            private var d_provider = Plexit.Provider.get();
            private var d_loading = false;
            private var d_collectionType = null;
            private var d_allCollections = [];
            private var d_search = "";
            private var d_visibleStart = 0;
            private const PAGE_SIZE = 20;
            private var d_browser = null;
            private var d_cursor = null;
            private var d_nextCursor = null;
            private var d_history = [];
            private var d_artist = null;
            private var d_pageReady = false;
            private var d_searchPending = false;
            private var d_searchTimer = null;
            private var d_source = null;

            function setArtist(id) { d_artist = id; }

            function usesServerPages() {
                return (d_collectionType == null) || d_collectionType.equals("album")
                    || d_collectionType.equals("artist");
            }

            function startPage() {
                if (d_browser != null) { d_browser.cancel(); }
                d_loading = true;
                d_allCollections = [];
                d_pageReady = false;
                d_browser = new PlexBrowse(method(:onPage), method(:onError));
                d_browser.start(d_collectionType, d_search, d_cursor, d_artist);
            }

            function onPage(collections, next) {
                d_browser = null;
                d_nextCursor = next;
                d_pageReady = true;
                d_allCollections = collections;
                // Page absence does not mean that a saved remote item was deleted.
                for (var i = 0; i < collections.size(); i += 1) {
                    var stored = new IPlaylist(collections[i].id());
                    if (stored.stored()) {
                        stored.updateMeta(collections[i]);
                        stored.setRemote(true);
                    }
                }
                rebuildItems();
                d_loading = false;
                MenuBase.onLoaded(null);
            }

            function reloadPage() {
                d_loading = true;
                unload();
                setOnLoaded(method(:onPageReloaded));
                // Release the old native menu and its rows while loading.
                WatchUi.switchToView(new TextView(placeholder()), new MenuLoadingDelegate(self), WatchUi.SLIDE_IMMEDIATE);
                startPage();
            }

            function onPageReloaded(error) {
                setOnLoaded(null);
                if (error != null) {
                    WatchUi.switchToView(new ErrorView(error), new MenuLoadingDelegate(self), WatchUi.SLIDE_IMMEDIATE);
                } else { replaceMenuView(); }
            }

            function initialize(title, collectionType) {
                MenuBase.initialize(title, false);
                d_collectionType = collectionType;
            }

            function playlist_to_item(playlist) {
                var sublabel = Plexit.I18n.songs(playlist.count());
                if (((d_collectionType != null) && d_collectionType.equals("album")
                    || (usesServerPages() && !d_search.equals("")))
                    && (playlist.subtitle() != null)) {
                    sublabel = playlist.subtitle();
				} else if ((d_collectionType != null) && d_collectionType.equals("collection")
					&& (playlist.subtitle() != null)) {
					sublabel = playlist.subtitle();
				} else if ((d_collectionType != null) && (playlist.count() == 0)) {
					if (d_collectionType.equals("album")) { sublabel = WatchUi.loadResource(Rez.Strings.Album_label); }
					else if (d_collectionType.equals("artist")) { sublabel = WatchUi.loadResource(Rez.Strings.Artist_label); }
					else { sublabel = WatchUi.loadResource(Rez.Strings.Genre_label); }
                }
                if (usesServerPages() && !d_search.equals("")
                    && (playlist.id().find("artist:") == 0)) {
                    sublabel = WatchUi.loadResource(Rez.Strings.BrowseAlbums_label);
                }
                if (!playlist.remote()) { sublabel += WatchUi.loadResource(Rez.Strings.LocalOnly_suffix); }
                var storedPlaylist = new IPlaylist(playlist.id());
                var enabled = storedPlaylist.stored()
                    ? storedPlaylist.local() : playlist.local();
                return {
                    LABEL => playlist.name(),
                    SUBLABEL => sublabel,
                    // Native menus should only carry stable primitive IDs. The
                    // matching remote object is resolved from d_allCollections.
                    METHOD => playlist.id(),
                    OPTION => (usesServerPages() && !d_search.equals("") && (playlist.id().find("artist:") == 0)) ? null : enabled,
                };
            }

            function load() {
                var source = Application.Storage.getValue(Plexit.Storage.PLEX_SERVER_ID);
                if (((d_source == null) && (source != null))
                    || ((d_source != null) && !d_source.equals(source))) {
                    resetBrowseState();
                    d_source = source;
                    d_provider = Plexit.Provider.get();
                }
                if (!PlexAccount.isConnected()) {
                    d_loading = false;
                    return MenuBase.load([]);
                }
                // Re-entering this cached menu must reflect selections persisted
                // by the previous native menu instance immediately.
                PlaylistStore.reload();
                if (d_pageReady || (d_allCollections.size() > 0)) {
                    rebuildItems();
                    return true;
                }
                if (d_loading) { return false; }
                d_loading = true;
                if (usesServerPages()) { startPage(); return false; }
				// All browse menus share the same provider. Register the fallback
				// immediately before this request so an error is returned to the
				// menu that is actually loading, not to whichever sibling menu was
				// constructed last.
				d_provider.setFallback(method(:onError));
                if (d_collectionType == null) {
                    d_provider.getAllPlaylists(method(:onGetAllCollections));
                } else if (d_collectionType.equals("album")) {
                    d_provider.getAllAlbums(method(:onGetAllCollections));
				} else if (d_collectionType.equals("genre")) {
					d_provider.getAllGenres(method(:onGetAllCollections));
				} else if (d_collectionType.equals("collection")) {
					d_provider.getAllPlexCollections(method(:onGetAllCollections));
                } else {
                    d_provider.getAllArtists(method(:onGetAllCollections));
                }
                return false;
            }

            function managesId(id) {
                if (!(id instanceof Lang.String)) { return false; }
                if (!PlexSource.belongsTo(id, d_source)) { return false; }
                if (d_collectionType == null) {
                    return (id.find("album:") != 0)
						&& (id.find("artist:") != 0)
						&& (id.find("collection:") != 0)
						&& (id.find("mix:") != 0)
						&& (id.find("genre:") != 0);
                }
                return id.find(d_collectionType + ":") == 0;
            }

            function onGetAllCollections(collections) {
                var ids = PlaylistStore.getIds();
                var relevantIds = [];
                for (var storedIdx = 0; storedIdx < ids.size(); ++storedIdx) {
                    if (managesId(ids[storedIdx])) { relevantIds.add(ids[storedIdx]); }
                }

                var stored = [];
                var remote = [];
                for (var idx = 0; idx < collections.size(); ++idx) {
                    var collection = collections[idx];
                    var id = collection.id();
                    if (relevantIds.indexOf(id) < 0) {
                        remote.add(collection);
                        continue;
                    }
                    var localCollection = new IPlaylist(id);
                    localCollection.setRemote(collection.remote());
                    localCollection.updateMeta(collection);
                    stored.add(localCollection);
                    relevantIds.remove(id);
                }

                for (var missingIdx = 0; missingIdx < relevantIds.size(); ++missingIdx) {
                    var missing = new IPlaylist(relevantIds[missingIdx]);
                    missing.setRemote(false);
                    stored.add(missing);
                }

                stored.addAll(remote);
                d_allCollections = stored;
                rebuildItems();
                d_loading = false;
                MenuBase.onLoaded(null);
            }

            function matchesSearch(playlist) {
                if (usesServerPages() || d_search.equals("")) { return true; }
                var query = d_search.toLower();
                if (playlist.name().toLower().find(query) != null) { return true; }
                return (playlist.subtitle() != null)
                    && (playlist.subtitle().toLower().find(query) != null);
            }

            function rebuildItems() {
                var menuItems = [];
                if ((d_collectionType != null) && (d_artist == null)) {
                    menuItems.add({
                        LABEL => WatchUi.loadResource(Rez.Strings.Search_label),
                        SUBLABEL => d_search.equals("")
                            ? WatchUi.loadResource(Rez.Strings.Search_hint) : d_search,
                        METHOD => method(:onSearch),
                    });
                    if (!d_search.equals("")) {
                        menuItems.add({
                            LABEL => WatchUi.loadResource(Rez.Strings.ClearSearch_label),
                            SUBLABEL => d_search,
                            METHOD => method(:onClearSearch),
                        });
                    }
                }
                if ((usesServerPages() && (d_history.size() > 0)) || (d_visibleStart > 0)) {
                    menuItems.add({
                        LABEL => WatchUi.loadResource(Rez.Strings.PreviousResults_label),
                        SUBLABEL => null,
                        METHOD => method(:onShowPrevious),
                    });
                }
                var matched = 0;
                for (var idx = 0; idx < d_allCollections.size(); ++idx) {
                    if (matchesSearch(d_allCollections[idx])) {
                        if ((matched >= d_visibleStart)
                            && (matched < (d_visibleStart + PAGE_SIZE))) {
                            menuItems.add(playlist_to_item(d_allCollections[idx]));
                        }
                        matched += 1;
                    }
                }
                if ((usesServerPages() && (d_nextCursor != null)) || (matched > (d_visibleStart + PAGE_SIZE))) {
                    menuItems.add({
                        LABEL => WatchUi.loadResource(Rez.Strings.ShowMore_label),
                        SUBLABEL => usesServerPages() ? null : Plexit.I18n.text(Rez.Strings.RemainingCount, [matched - d_visibleStart - PAGE_SIZE]),
                        METHOD => method(:onShowMore),
                    });
                }
                MenuBase.load(menuItems);
            }

            function onShowMore() {
                if (usesServerPages()) {
                    d_history.add(d_cursor);
                    d_cursor = d_nextCursor;
                    reloadPage();
                    return;
                }
                d_visibleStart += PAGE_SIZE;
                rebuildItems();
                replaceMenuView();
            }

            function onShowPrevious() {
                if (usesServerPages()) {
                    d_cursor = d_history[d_history.size() - 1];
                    d_history = d_history.slice(0, d_history.size() - 1);
                    reloadPage();
                    return;
                }
                d_visibleStart -= PAGE_SIZE;
                if (d_visibleStart < 0) { d_visibleStart = 0; }
                rebuildItems();
                replaceMenuView();
            }

            function replaceMenuView() {
                WatchUi.switchToView(
                    new MenuView(self),
                    delegate(),
                    WatchUi.SLIDE_IMMEDIATE
                );
            }

            function onSearch() {
                WatchUi.pushView(
                    new WatchUi.TextPicker(d_search),
                    new CollectionSearchDelegate(self),
                    WatchUi.SLIDE_IMMEDIATE
                );
            }

            function setSearch(search) {
                d_search = (search == null) ? "" : search;
                d_visibleStart = 0;
                if (usesServerPages()) {
                    d_cursor = null;
                    d_history = [];
                    if (d_browser != null) { d_browser.cancel(); }
                    // Defer the view switch until the native TextPicker has
                    // closed and MenuView.onShow has returned. Switching views
                    // inside onShow re-enters the simulator's native UI stack.
                    d_searchPending = true;
                    if (d_searchTimer != null) { d_searchTimer.stop(); }
                    d_searchTimer = new Timer.Timer();
                    d_searchTimer.start(method(:resumeSearch), 100, false);
                    return;
                }
                rebuildItems();
            }

            function resumeSearch() {
                if (!d_searchPending) { return; }
                d_searchPending = false;
                d_searchTimer = null;
                reloadPage();
            }

            function onClearSearch() {
                if (usesServerPages()) {
                    setSearch("");
                    d_searchPending = false;
                    if (d_searchTimer != null) { d_searchTimer.stop(); d_searchTimer = null; }
                    reloadPage();
                    return;
                }
                d_search = "";
                d_visibleStart = 0;
                rebuildItems();
                replaceMenuView();
            }

            function placeholder() {
                if (!PlexAccount.isConnected()) {
                    return WatchUi.loadResource(Rez.Strings.PlexNotConnected);
                }
                if (d_loading) {
                    if (d_collectionType == null) {
                        return WatchUi.loadResource(Rez.Strings.fetchingPlaylists);
                    }
					if (d_collectionType.equals("album")) {
                        return WatchUi.loadResource(Rez.Strings.fetchingAlbums);
                    }
					if (d_collectionType.equals("genre")) {
						return WatchUi.loadResource(Rez.Strings.fetchingGenres);
					}
					if (d_collectionType.equals("collection")) {
						return WatchUi.loadResource(Rez.Strings.fetchingCollections);
					}
                    return WatchUi.loadResource(Rez.Strings.fetchingArtists);
                }
                return WatchUi.loadResource(Rez.Strings.placeholder_noRemotePlaylists);
            }

            function onError(error) {
                d_browser = null;
                d_loading = false;
                MenuBase.onLoaded(error);
            }

            function onPlaylistToggle(item) {
                var id = item.getId();
                if (usesServerPages() && !d_search.equals("") && (id.find("artist:") == 0)) {
                    var artist = findCollection(id);
                    if (artist == null) { return; }
                    var albums = new PlaylistsRemoteToggle(artist.name(), "album");
                    albums.setArtist(id.substring(7, id.length()));
                    albums.onOpen();
                    return;
                }
                var playlist = findCollection(id);
                if (playlist == null) {
                    Plexit.Utils.log("Offline selection ignored: missing collection " + id);
                    return;
                }
                var localPlaylist = new IPlaylist(id);
                if (item.isEnabled()) {
                    // Persist the remote metadata first, then mark it local. This
                    // makes the synthetic album/artist visible to pending-sync
                    // readers immediately, even when Plex omitted leafCount.
                    localPlaylist.updateMeta(playlist);
                }
                var saved = localPlaylist.setLocal(item.isEnabled());
                var persisted = new IPlaylist(id);
                Plexit.Utils.log("Offline selection: id=" + id
                    + ", enabled=" + item.isEnabled()
                    + ", saved=" + saved
                    + ", stored=" + persisted.stored()
                    + ", local=" + persisted.local());
            }

            function findCollection(id) {
                for (var idx = 0; idx < d_allCollections.size(); ++idx) {
                    if (d_allCollections[idx].id().equals(id)) {
                        return d_allCollections[idx];
                    }
                }
                return null;
            }

            function onLoadingBack() { onBrowseBack(); }

            function onBrowseBack() {
                setOnLoaded(null);
                resetBrowseState();
                return false;
            }

            function resetBrowseState() {
                if (d_browser != null) { d_browser.cancel(); d_browser = null; }
                d_pageReady = false;
                d_searchPending = false;
                if (d_searchTimer != null) { d_searchTimer.stop(); d_searchTimer = null; }
                d_cursor = null;
                d_nextCursor = null;
                d_history = [];
                // AddMusic keeps its child menu objects alive for fast navigation.
                // Do not let a complete Plex album/artist catalogue survive into
                // an immediate audio sync, where it substantially increases the
                // memory peak while Garmin commits downloaded media metadata.
                d_allCollections = [];
                d_search = "";
                d_visibleStart = 0;
                d_loading = false;
                unload();
            }

            function delegate() {
                return new MenuDelegate(method(:onPlaylistToggle), method(:onBrowseBack));
            }
        }
    }
}
