using Toybox.System;
using Toybox.Application;
using Toybox.Lang;
using Plexit.Storage;

/**
 * module SongStore
 * 
 * access to application storage for songs
 */
 
class Id {
 	private var d_id;
 	
 	function initialize(id) {
 		d_id = id;
 	}
 	
 	function toStorage() {
 		return d_id;
 	}
}

module SongStore {

	var d_songs = new KeyedStore(Storage.SONG_PREFIX, Storage.SONG_IDS);
	var d_delete = new ArrayStore(Storage.SONGS_DELETE);	// allows fast access 
	var d_songTodos = new ArrayStore(Storage.SONGS_TODO);	// allows fast access

	function get(id) {
		return d_songs.get(id);
	}

	function getIds() {
		return d_songs.getIds();
	}

	// Avoids building an ISong (and its artwork) per song in whole-library
	// scans, which trips the watchdog now that each song is a storage read.
	function isCached(id) {
		var song = d_songs.get(id);
		return (song != null) && (song["refId"] != null);
	}

	function getTodos() {
		var ret = new [d_songTodos.size()];
		for (var idx = 0; idx != d_songTodos.size(); ++idx) {
			ret[idx] = d_songTodos.get(idx);
		}
		return ret;
	}

	function getDeletes() {
		var ret = new [d_delete.size()];
		for (var idx = 0; idx < d_delete.size(); ++idx) {
			ret[idx] = d_delete.get(idx);
		}
		return ret;
	}

	function reset() {
		d_songs.reset();
		d_delete.reset();
		d_songTodos.reset();
	}

	// Songs used to share the single SONGS value; rewrite them one key each.
	// Idempotent, so an interrupted migration completes on the next start.
	function migrate() {
		var legacy = Application.Storage.getValue(Storage.SONGS);
		if (!(legacy instanceof Lang.Dictionary)) {
			return;
		}
		d_songs.defer();
		var values = legacy.values();
		legacy = null;
		for (var idx = 0; idx < values.size(); ++idx) {
			var value = values[idx];
			if ((value instanceof Lang.Dictionary) && (value["id"] != null)) {
				d_songs.put(value["id"], value);
			}
		}
		if (d_songs.flush()) {
			Application.Storage.deleteValue(Storage.SONGS);
		}
	}

	function beginBatch() {
		d_songs.defer();
		d_delete.defer();
		d_songTodos.defer();
	}

	function endBatch() {
		var success = d_songs.flush();
		success = d_delete.flush() && success;
		return d_songTodos.flush() && success;
	}

    // these functions should be used only internally by ISong class
	function save(song) {
		// update delete tracking
		var id = new Id(song.id());
		var delete = (song.refCount() <= 0);
		var ondelete = (d_delete.indexOf(id) >= 0);
		if (delete && !ondelete) {
			d_delete.add(id);
			d_songTodos.remove(id);
		} else if (!delete && ondelete) {
			d_delete.remove(id);
		}
		// update todo tracking
		var todo = (song.refId() == null);
		var ontodo = (d_songTodos.indexOf(id) >= 0);
		if (!delete && todo && !ontodo) {
			d_songTodos.add(id);
		} else if (!todo && ontodo) {
			d_songTodos.remove(id);
		}

		// save details of the song
		return d_songs.save(song);
	}

	// this is for fast property saving. refCount or refId changed? use save
	function quicksave(song) {
		// save details of the song
		return d_songs.save(song);
	}

	function remove(song) {
		// remove from storage
		d_songs.remove(song);

        // if not on delete, nothing to do
        var id = new Id(song.id());
        if (d_delete.indexOf(id) < 0) {
            return;
        }

		// remove from delete
        d_delete.remove(id);
	}
}
