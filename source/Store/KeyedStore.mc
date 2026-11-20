using Toybox.Application;
using Toybox.Lang;

/*
 * Store each item under its own storage key, plus an array of all ids.
 * Item class should have a function id()
 * Item class should have a function toStorage()
 *
 * A single Dictionary value fails to save (as an uncatchable out of memory
 * error) once it outgrows the per-value storage limit, so collections that
 * grow with the library must not share one key.
 */
class KeyedStore {

	private var d_prefix;	// prefix for the storage key of each item
	private var d_ids;		// array of all stored item ids
	private var d_pending = null;	// key -> value written on flush() while deferred

	function initialize(prefix, idsKey) {
		d_prefix = prefix.toString();
		d_ids = new ArrayStore(idsKey);
	}

	function get(id) {
		if (id == null) {
			return null;
		}
		var itemKey = key(id);
		if ((d_pending != null) && d_pending.hasKey(itemKey)) {
			return d_pending[itemKey];
		}
		return Application.Storage.getValue(itemKey);
	}

	function getIds() {
		return d_ids.value().slice(0, null);
	}

	function save(item) {
		return put(item.id(), item.toStorage());
	}

	function put(id, value) {
		// return false if failed save
		if (id == null) {
			return false;
		}
		if (d_pending != null) {
			d_pending.put(key(id), value);
		} else if (!write(key(id), value)) {
			return false;
		}
		var storedId = new Id(id);
		if (d_ids.indexOf(storedId) < 0) {
			return d_ids.add(storedId);
		}
		return true;
	}

	// returns true if item id entry removed from storage or is not in storage
	function remove(item) {
		var id = item.id();
		if (id == null) {
			return true;
		}
		if (d_pending != null) {
			d_pending.remove(key(id));
		}
		Application.Storage.deleteValue(key(id));
		return d_ids.remove(new Id(id));
	}

	function reset() {
		d_pending = null;
		d_ids.reset();
	}

	// An item is saved several times while a playlist updates its songs;
	// keep the latest value and write each item once.
	function defer() {
		d_pending = {};
		d_ids.defer();
	}

	function flush() {
		var success = true;
		if (d_pending != null) {
			var keys = d_pending.keys();
			for (var idx = 0; idx < keys.size(); ++idx) {
				success = write(keys[idx], d_pending[keys[idx]]) && success;
			}
			d_pending = null;
		}
		return d_ids.flush() && success;
	}

	function write(itemKey, value) {
		try {
			Application.Storage.setValue(itemKey, value);
		} catch (exception instanceof Lang.StorageFullException) {
			return false;
		}
		return true;
	}

	function key(id) {
		return d_prefix + id.toString();
	}
}
