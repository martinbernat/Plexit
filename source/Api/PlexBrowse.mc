using Toybox.Lang;
using Toybox.Communications;
using Toybox.System;

// One short-lived session per page/search. It never shares mutable callbacks
// with the sync provider, and a cancelled response cannot touch a native view.
class PlexBrowse {
    private var d_api;
    private var d_source;
    private var d_callback;
    private var d_fallback;
    private var d_cancelled = false;
    private var d_type;
    private var d_query;
    private var d_artist;
    private var d_sections = [];
    private var d_section = 0;
    private var d_offset = 0;
    private const PAGE_SIZE = 20;
    private var d_limit = PAGE_SIZE;
    private var d_searchLimit = 10;
    private var d_requestKind = "sections";

    function initialize(callback, fallback) {
        d_callback = callback;
        d_fallback = fallback;
        var settings = Plexit.Provider.getProviderSettings();
        d_source = settings["server_id"];
        d_api = new PlexAPI(settings, null, method(:onError));
    }

    function cancel() {
        d_cancelled = true;
        d_api.cancelRequests();
        d_callback = null;
        d_fallback = null;
    }

    function start(type, query, cursor, artist) {
        if (!d_api.isAvailable()) { onError(new Plexit.ApiError(Plexit.ApiError.ACCESS)); return; }
        d_type = type;
        d_query = query;
        d_artist = PlexSource.raw(artist);
        if (cursor != null) {
            d_section = cursor["section"];
            d_offset = cursor["offset"];
        }
        if ((artist != null) || ((type == null) && query.equals(""))) {
            requestPage();
        } else {
            d_api.library_sections(method(:onSections), {});
        }
    }

    function onSections(response) {
        if (d_cancelled) { return; }
        var sections = response["Directory"];
        if (sections instanceof Lang.Dictionary) { sections = [sections]; }
        if (sections instanceof Lang.Array) {
            for (var i = 0; i < sections.size(); i += 1) {
                if (isType(sections[i]["type"], "artist") && (sections[i]["key"] != null)) {
                    d_sections.add(sections[i]["key"].toString());
                }
            }
        }
        Plexit.Utils.log("Browse music sections: " + d_sections.size());
        if (d_sections.size() == 0) { complete([], null); return; }
        if (!d_query.equals("")) { requestSearch(); }
        else { requestPage(); }
    }

    function isType(value, expected) {
        // Monkey C == compares String identity, not their contents. Network
        // strings must use equals(), or music sections/hubs silently disappear.
        return (value instanceof Lang.String) && value.equals(expected);
    }

    function leanParams() {
        return {
            "excludeFields" => "summary,guid,art,theme,addedAt,updatedAt,index,originallyAvailableAt,contentRating,rating,viewCount,lastViewedAt,ultraBlurColors",
            "excludeElements" => "Genre,Country,Collection,Guid,Image,Similar,Location,Mood,Style",
        };
    }

    function requestPage() {
        if (d_cancelled) { return; }
        var params = leanParams();
        params.put("X-Plex-Container-Start", d_offset);
        params.put("X-Plex-Container-Size", d_limit);
        d_requestKind = "page";
        params.put("sort", "titleSort:asc");
        Plexit.Utils.log("Browse page: type=" + d_type + ", section=" + d_section + ", offset=" + d_offset);
        if (d_artist != null) {
            d_api.metadata_children(method(:onPage), params, d_artist);
        } else if (d_type == null) {
            params.put("playlistType", "audio");
            d_api.playlists(method(:onPage), params);
        } else if (d_section < d_sections.size()) {
            params.put("type", d_type.equals("album") ? 9 : 8);
            d_api.library_section_all(method(:onPage), params, d_sections[d_section]);
        } else { complete([], null); }
    }

    function onPage(response) {
        if (d_cancelled) { return; }
        var metadata = response["Metadata"];
        if (metadata instanceof Lang.Dictionary) { metadata = [metadata]; }
        if (!(metadata instanceof Lang.Array)) { metadata = []; }
        // A server ignoring the range must not silently return a whole catalogue.
        if (metadata.size() > d_limit) {
            onError(new Plexit.ApiError(Plexit.ApiError.BADRESPONSE));
            return;
        }
        var items = [];
        for (var i = 0; i < metadata.size(); i += 1) {
            items.add(toCollection(metadata[i], d_type));
        }
        var next = null;
        var total = response["totalSize"];
        var hasMore = (total != null)
            ? ((d_offset + metadata.size()) < total.toNumber())
            : (metadata.size() == d_limit);
        if (hasMore && (metadata.size() > 0)) {
            next = {"section" => d_section, "offset" => d_offset + metadata.size()};
        } else if ((d_artist == null) && (d_type != null)
            && ((d_section + 1) < d_sections.size())) {
            next = {"section" => d_section + 1, "offset" => 0};
        }
        if ((items.size() == 0) && (next != null)) {
            d_section = next["section"];
            d_offset = next["offset"];
            requestPage();
            return;
        }
        complete(items, next);
    }

    function requestSearch() {
        var params = leanParams();
        params.put("query", d_query);
        params.put("limit", d_searchLimit);
        d_requestKind = "search";
        // sectionId only supplies context on some PMS versions. Validate each
        // item's librarySectionID below rather than trusting this parameter.
        params.put("sectionId", d_sections[0]);
        d_api.hubs_search(method(:onSearch), params);
    }

    function onSearch(response) {
        if (d_cancelled) { return; }
        var hubs = response["Hub"];
        if (hubs instanceof Lang.Dictionary) { hubs = [hubs]; }
        var items = [];
        if (hubs instanceof Lang.Array) {
            for (var h = 0; h < hubs.size(); h += 1) {
                var type = hubs[h]["type"];
                if (!isType(type, "artist") && !isType(type, "album")) { continue; }
                var metadata = hubs[h]["Metadata"];
                if (metadata == null) { metadata = hubs[h]["Directory"]; }
                if (metadata instanceof Lang.Dictionary) { metadata = [metadata]; }
                if (!(metadata instanceof Lang.Array)) { continue; }
                for (var i = 0; (i < metadata.size()) && (items.size() < PAGE_SIZE); i += 1) {
                    var section = metadata[i]["librarySectionID"];
                    if ((section == null) || (d_sections.indexOf(section.toString()) < 0)) { continue; }
                    if (!isType(metadata[i]["type"], type)) { continue; }
                    var item = toCollection(metadata[i], type);
                    var duplicate = false;
                    for (var j = 0; j < items.size(); j += 1) {
                        if (items[j].id().equals(item.id())) { duplicate = true; break; }
                    }
                    if (!duplicate) { items.add(item); }
                }
            }
        }
        // Hub search is a ranked preview. Its `more` flag is not a reliable
        // cursor; artist selection opens a separately paged album catalogue.
        complete(items, null);
    }

    function toCollection(item, type) {
        var count = item["leafCount"];
        if (count == null) { count = item["childCount"]; }
        if (count == null) { count = 0; }
        return new Playlist({
            "id" => PlexSource.qualify(d_source, (type == null) ? item["ratingKey"].toString() : type + ":" + item["ratingKey"]),
            "name" => item["title"],
            "subtitle" => isType(type, "album") ? item["parentTitle"] : null,
            "songCount" => count.toNumber(),
            "remote" => true,
        });
    }

    function complete(items, next) {
        if (d_cancelled) { return; }
        Plexit.Utils.log("Browse received " + items.size() + " items; free memory=" + System.getSystemStats().freeMemory);
        var callback = d_callback;
        cancel();
        callback.invoke(items, next);
    }

    function onError(error) {
        if (d_cancelled) { return; }
        if ((error instanceof Plexit.GarminSdkError)
            && PlexServerRequest.isResponseTooBig(error.respCode())) {
            if ((d_requestKind.equals("page")) && (d_limit > 1)) {
                d_limit = (d_limit / 2).toNumber();
                Plexit.Utils.log("Browse response too large; retrying " + d_limit + " items");
                requestPage();
                return;
            }
            if ((d_requestKind.equals("search")) && (d_searchLimit > 1)) {
                d_searchLimit = (d_searchLimit / 2).toNumber();
                Plexit.Utils.log("Search response too large; retrying limit=" + d_searchLimit);
                requestSearch();
                return;
            }
        }
        var fallback = d_fallback;
        cancel();
        fallback.invoke(error);
    }
}
