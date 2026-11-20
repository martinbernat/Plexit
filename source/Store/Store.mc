using Toybox.Application;
using Toybox.System;

class Store {

	private var d_key;			// key to set/retrieve the stored data
	private var d_value = null;	// variable that is reflected in the Application.Storage
	private var d_deferred = false;
	private var d_dirty = false;

	function initialize(key, value) {
		d_key = key;

		var stored = Application.Storage.getValue(d_key);
		if (stored != null) {
			d_value = stored;
			return;
		}
		d_value = value;
	}

	function value() {
		return d_value;
	}
	
	function setValue(value) {
		d_value = value;
	}

	// Replace the in-memory mirror without writing it back. Used after
	// Application.Storage.clearValues(), where the persisted data is already gone.
	function reset(value) {
		d_value = value;
		d_dirty = false;
	}

	// Refresh the in-memory mirror after returning from another native media
	// view/runtime context. Audio provider screens may keep an older module
	// instance alive even though Application.Storage already contains a newer
	// value written by the screen that was just popped.
	function reload(fallback) {
		var stored = Application.Storage.getValue(d_key);
		d_value = (stored == null) ? fallback : stored;
		return d_value;
	}

	// Each update() serializes the whole value, so per-item saves in a loop
	// are O(items * stored) and trip the watchdog or run out of memory.
	// Callers updating many items defer() and flush() once afterwards.
	function defer() {
		d_deferred = true;
	}

	function flush() {
		d_deferred = false;
		if (!d_dirty) {
			return true;
		}
		d_dirty = false;
		return update();
	}

	function update() {
		if (d_deferred) {
			d_dirty = true;
			return true;
		}
		var success = true;
		try {
			Application.Storage.setValue(d_key, d_value);
		} catch (exception instanceof Toybox.Lang.StorageFullException) {
			success = false;
		}
		return success;
	}
}
