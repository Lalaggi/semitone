namespace G4 {

    private const string BINIMUM_API_BASE_URL = "https://lyrics-api.binimum.org/";

    // ISRC: 2-letter country + 3-char registrant + 2-digit year + 5-digit designation
    private string? binimum_find_isrc (string text) {
        try {
            var re = new Regex ("\\b[A-Z]{2}[A-Z0-9]{3}\\d{2}\\d{5}\\b");
            MatchInfo info;
            if (re.match (text.up (), 0, out info)) {
                var m = info.fetch (0);
                if (m != null && ((!)m).length == 12) return (!)m;
            }
        } catch (RegexError e) {}
        return null;
    }

    private string? binimum_isrc_for_music (Music music) {
        var found = binimum_find_isrc (music.comment);
        if (found != null) return found;
        var metadata_text = get_all_string_metadata_text (music.uri);
        if (metadata_text == null) return null;
        return binimum_find_isrc ((!)metadata_text);
    }

    private async LyricsCandidate? binimum_fetch_from_url (string lyrics_url, int index, GLib.Cancellable? cancellable) {
        var body = yield lyrics_http_get (lyrics_url, cancellable);
        if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
        if (body == null || ((!)body).strip ().length == 0) return null;
        return lyrics_build_candidate ((!)body, "BiniLyrics", index);
    }

    private async LyricsCandidate? binimum_fetch_query (string query_url, string song, string artist, int index, GLib.Cancellable? cancellable) {
        var body = yield lyrics_http_get (query_url, cancellable);
        if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
        if (body == null) return null;
        try {
            var parser = new Json.Parser ();
            parser.load_from_data ((!)body);
            var root = parser.get_root ()?.get_object ();
            if (root == null) return null;
            var obj = (!)root;
            if (obj.has_member ("error")) return null;
            if (!obj.has_member ("results")) return null;
            var arr = obj.get_array_member ("results");
            if (arr == null) return null;
            string[] urls = {};
            ((!)arr).foreach_element ((a, i, node) => {
                var entry = node.get_object ();
                if (entry == null) return;
                var e = (!)entry;
                // Verify it's actually our song (same wrong-hit hazard as Unison)
                var track = unison_get_string_member (e, "track_name");
                if (track.length == 0) track = unison_get_string_member (e, "song");
                var performer = unison_get_string_member (e, "artist_name");
                if (performer.length == 0) performer = unison_get_string_member (e, "artist");
                if (!unison_text_matches (track, song) || !unison_text_matches (performer, artist)) {
                    if (lyrics_debug_enabled)
                        lyrics_log ("BiniLyrics: skipping '%s' by '%s'".printf (track, performer));
                    return;
                }
                var url = unison_get_string_member (e, "lyricsUrl");
                if (url.length > 0) urls += url;
            });
            var limit = int.min (3, urls.length);
            for (var i = 0; i < limit; i++) {
                if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
                var c = yield binimum_fetch_from_url (urls[i], index, cancellable);
                if (c != null) return c;
            }
            return null;
        } catch (Error e) {
            if (lyrics_debug_enabled)
                lyrics_log ("BiniLyrics: %s".printf (e.message));
            return null;
        }
    }

    public async LyricsCandidate? provider_fetch_binimum (Music music, int duration_ms, Settings settings, int index, GLib.Cancellable? cancellable = null) {
        if (!settings.get_boolean ("lyrics-binimum-enabled")) {
            lyrics_log ("BiniLyrics: disable");
            return null;
        }

        // ISRC lookup is exact — prefer it when tags carry one
        var isrc = binimum_isrc_for_music (music);
        if (isrc != null) {
            var url = "%s?isrc=%s".printf (
                BINIMUM_API_BASE_URL, Uri.escape_string ((!)isrc, null, false));
            var c = yield binimum_fetch_query (url, music.title, music.artist, index, cancellable);
            if (c != null) return c;
            if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
        }

        var url = "%s?track=%s&artist=%s".printf (
            BINIMUM_API_BASE_URL,
            Uri.escape_string (music.title, null, false),
            Uri.escape_string (music.artist, null, false));
        if (music.album.length > 0)
            url += "&album=%s".printf (Uri.escape_string (music.album, null, false));
        if (duration_ms > 0)
            url += "&duration=%d".printf (duration_ms);
        return yield binimum_fetch_query (url, music.title, music.artist, index, cancellable);
    }
}
