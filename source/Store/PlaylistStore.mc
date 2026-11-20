using Plexit.Storage;
using Toybox.Application;
using Toybox.Lang;
using Toybox.System;

module PlaylistStore {
    var d_store = new ObjectStore(Storage.PLAYLISTS);
    var d_rev = null;	// PLAYLISTS_REV matching d_store, null forces a full reload

    function get(id) {
		reload();
        return d_store.get(id);
    }

    function getIds() {
		reload();
        return d_store.getIds();
    }

    function save(playlist) {
		// Merge with the latest persistent value instead of a possibly stale
		// dictionary retained by another native view/runtime context.
		reload();
        return bumpRev(d_store.save(playlist));
    }

    function remove(playlist) {
		reload();
        return bumpRev(d_store.remove(playlist));
    }

	function reset() {
		d_store.reset();
		d_rev = null;
	}

	// Other native view contexts may have written PLAYLISTS since our last
	// read; a full getValue deserializes every playlist's song list, so only
	// do it when the persisted revision moved.
	function reload() {
		var rev = Application.Storage.getValue(Storage.PLAYLISTS_REV);
		if ((rev == null) || (rev != d_rev)) {
			d_store.reload();
			d_rev = rev;
		}
	}

	function bumpRev(success) {
		var rev = Application.Storage.getValue(Storage.PLAYLISTS_REV);
		rev = (rev instanceof Lang.Number) ? rev + 1 : 1;
		try {
			Application.Storage.setValue(Storage.PLAYLISTS_REV, rev);
			d_rev = success ? rev : null;
		} catch (exception instanceof Lang.StorageFullException) {
			// Without a revision every context falls back to a full reload.
			Application.Storage.deleteValue(Storage.PLAYLISTS_REV);
			d_rev = null;
		}
		return success;
	}

	function debugState(context) {
		var stored = Application.Storage.getValue(Storage.PLAYLISTS);
		if (!(stored instanceof Lang.Dictionary)) {
			Plexit.Utils.log("PlaylistStore[" + context + "]: no persisted dictionary");
			return;
		}
		var values = stored.values();
		var localCount = 0;
		for (var idx = 0; idx < values.size(); ++idx) {
			var value = values[idx];
			if ((value instanceof Lang.Dictionary) && (value["local"] == true)) {
				localCount += 1;
				Plexit.Utils.log("PlaylistStore[" + context + "]: local id=" + value["id"]
					+ ", synced=" + value["synced"]);
			}
		}
		Plexit.Utils.log("PlaylistStore[" + context + "]: total=" + values.size()
			+ ", local=" + localCount);
	}
}
