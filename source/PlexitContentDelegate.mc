using Toybox.Media;
using Toybox.System;
using Plexit;
using Plexit.ScrobbleStore;
using Plexit.RatingStore;

// This class handles events from the system's media
// player. getContentIterator() returns an iterator
// that iterates over the songs configured to play.
class PlexitContentDelegate extends Media.ContentDelegate {

	private var d_iterator;
	
    function initialize() {
        ContentDelegate.initialize();

        resetContentIterator();
    }

    // Returns an iterator that is used by the system to play songs.
    // A custom iterator can be created that extends Media.ContentIterator
    // to return only songs chosen in the sync configuration mode.
    function getContentIterator() {
		setCurrentAlbumArt();
        return d_iterator;
    }

	function setCurrentAlbumArt() {
		var playable = new Plexit.IPlayable();
		if (playable.size() == 0) {
			Media.setAlbumArt(null);
			return;
		}
		var index = playable.songidx();
		if ((index < 0) || (index >= playable.size())) {
			index = 0;
		}
		setAudioArtwork(playable.getAudio(index));
	}

	function setAudioArtwork(audio) {
		if (!(audio instanceof Plexit.Audio)) {
			Plexit.Utils.log("Playback artwork: audio lookup failed");
			Media.setAlbumArt(null);
			return;
		}
		var artwork = audio.artwork();
		Plexit.Utils.log("Playback artwork: song=" + audio.id()
			+ ", available=" + (artwork != null));
		try {
			Media.setAlbumArt(artwork);
		} catch (error) {
			Plexit.Utils.log("Playback artwork rejected: " + error);
			Media.setAlbumArt(null);
		}
	}

    // Respond to a user ad click
    function onAdAction(adContext) {
    }
    
    function onCustomButton(button) {
    }

    // Respond to a thumbs-up action
    function onThumbsUp(contentRefId) {
        queueRating(contentRefId, 10);
    }

    // Respond to a thumbs-down action
    function onThumbsDown(contentRefId) {
        queueRating(contentRefId, 0);
    }

    function queueRating(contentRefId, value) {
        try {
            var audio = findAudioByRefId(contentRefId);
            if (!(audio instanceof Plexit.Audio)) {
                Plexit.Utils.log("Rating ignored: no matching local song");
                return;
            }
            RatingStore.reload();
            var saved = RatingStore.add(new Plexit.Rating({
                "id" => audio.id(),
                "value" => value,
            }));
            Plexit.Utils.log("Rating queued: song=" + audio.id()
                + ", value=" + value + ", saved=" + saved);
        } catch (error) {
            // Rating is optional. Never allow a stale native ContentRef callback
            // to terminate playback.
            Plexit.Utils.log("Ignoring rating callback error: " + error);
        }
    }

    // Respond to a command to turn shuffle on or off
    function onShuffle() {
    	d_iterator.toggleShuffle();
    }
    
    function onRepeat() {
		d_iterator.toggleRepeat();
    }
    
    function resetContentIterator() {
    	d_iterator = new PlexitContentIterator();
    	return d_iterator;
    }
    
    function onMore() {
    }
    
    function onLibrary() {
    }

    // Handles a notification from the system that an event has
    // been triggered for the given song
    function onSong(contentRefId, songEvent as Media.SongEvent, playbackPosition) as Void {
		try {
			handleSong(contentRefId, songEvent, playbackPosition);
		} catch (error) {
			// ContentRef IDs are opaque platform objects and native callbacks may
			// arrive while the queue/cache is being replaced. Never let an optional
			// artwork or scrobble action terminate playback.
			Plexit.Utils.log("Ignoring playback callback error: " + error);
		}
	}

	function handleSong(contentRefId, songEvent, playbackPosition) {
		// Opening the native player menu can emit pause/stop events. They do not
		// require a song lookup and opaque ContentRef IDs are not guaranteed to
		// support every equality operation in all simulator/device runtimes.
		if ((songEvent != Media.SONG_EVENT_START)
			&& (songEvent != Media.SONG_EVENT_PLAYBACK_NOTIFY)) {
			return;
		}

		var audio = findAudioByRefId(contentRefId);
		if (audio == null) {
			Plexit.Utils.log("Playback callback: no matching local song");
			return;
		}
		
		if (songEvent == Media.SONG_EVENT_START) {
			// set the artwork
			setAudioArtwork(audio);
			return;
		}

	    	if (songEvent == Media.SONG_EVENT_PLAYBACK_NOTIFY) {
			// record a play
    		ScrobbleStore.add(new Plexit.Scrobble({
    			"id" => audio.id(),
    		}));
    		return;
    	}
    	
    }

	function findAudioByRefId(refId) {
		// trick: guess id and type from playable
		var iplayable = new Plexit.IPlayable();
		var audio = iplayable.getAudio(iplayable.songidx());
		if ((audio instanceof Plexit.Audio)
			&& refIdsEqual(audio.refId(), refId)) {
			return audio;
		}
		// if trick not successful, do exhaustive search
		var ids = SongStore.getIds();
		for (var idx = 0; idx != ids.size(); ++idx) {
				var song = SongStore.get(ids[idx]);

				// return if correct
				if ((song != null) && refIdsEqual(song["refId"], refId)) {
					return new Audio(ids[idx], Audio.SONG);
				}
		}
		return null;
	}

	function refIdsEqual(left, right) {
		if ((left == null) || (right == null)) {
			return (left == null) && (right == null);
		}
		return left.toString().equals(right.toString());
	}
    
    function findSongByRefId(refId) {
		var ids = SongStore.getIds();
		for (var idx = 0; idx < ids.size(); ++idx) {
			var isong = new ISong(ids[idx]);
			if (refId == isong.refId()) {
				return isong;
			}
		}
		return null;
	}
    
    function getSongName(refId) {
    	return Media.getCachedContentObj(new Media.ContentRef(refId, Media.CONTENT_TYPE_AUDIO)).getMetadata().title;
    }
}
