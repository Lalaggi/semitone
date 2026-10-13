namespace G4 {

    public async LyricsCandidate? provider_fetch_lrclib (Music music, int duration_ms, Settings settings, int index, GLib.Cancellable? cancellable = null) {
        if (!settings.get_boolean ("lyrics-lrclib-enabled")) {
            lyrics_log ("LRCLib: disable");
            return null;
        }

        var url = "https://lrclib.net/api/search?track_name=%s&artist_name=%s&album_name=%s".printf (
            Uri.escape_string (music.title, null, false),
            Uri.escape_string (music.artist, null, false),
            Uri.escape_string (music.album, null, false));
        var body = yield lyrics_http_get (url, cancellable);
        if (body == null) return null;
        try {
            var parser = new Json.Parser ();
            parser.load_from_data ((!)body);
            var root_arr = parser.get_root ()?.get_array ();
            if (root_arr == null) return null;
            var arr = (!)root_arr;
            if (arr.get_length () < 1) return null;
            var first_obj_node = arr.get_element (0);
            var first_obj = first_obj_node.get_object ();
            if (first_obj == null) return null;
            var obj = (!)first_obj;
            if (!obj.has_member ("trackName")) return null;
            bool instrumental = false;
            try {
                if (obj.has_member ("instrumental"))
                    instrumental = obj.get_boolean_member ("instrumental");
            } catch {}
            string synced_val = "";
            string plain_val = "";
            string? raw_synced = obj.get_string_member ("syncedLyrics");
            if (raw_synced != null) synced_val = (!)raw_synced;
            string? raw_plain = obj.get_string_member ("plainLyrics");
            if (raw_plain != null) plain_val = (!)raw_plain;
            return lyrics_build_lrclib_candidate (synced_val, plain_val, instrumental, index);
        } catch (Error e) {
            return null;
        }
    }

    private LyricsCandidate? lyrics_build_lrclib_candidate (string synced, string plain, bool instrumental, int index) {
        if (instrumental) {
            LyricsCandidate c = { "[instrumental]", "LRCLib", {}, false, 0, LyricsFormat.PLAIN };
            return c;
        }
        if (synced.length > 0) {
            var parsed = parse_lrc (synced);
            if (parsed.length > 0) {
                if (lyrics_lines_are_instrumental_only (parsed)) {
                    LyricsCandidate ic = { "[instrumental]", "LRCLib", {}, false, 0, LyricsFormat.PLAIN };
                    return ic;
                }
                var score = lyrics_score_candidate (parsed, LyricsFormat.LRC, index, "LRCLib");
                LyricsCandidate c = { synced, "LRCLib", parsed, true, score, LyricsFormat.LRC };
                return c;
            }
        }
        if (plain.length > 0) {
            var parsed = parse_plain (plain);
            if (parsed.length > 0) {
                if (lyrics_lines_are_instrumental_only (parsed)) {
                    LyricsCandidate ic = { "[instrumental]", "LRCLib", {}, false, 0, LyricsFormat.PLAIN };
                    return ic;
                }
                var score = lyrics_score_candidate (parsed, LyricsFormat.PLAIN, index, "LRCLib");
                LyricsCandidate c = { plain, "LRCLib", parsed, false, score, LyricsFormat.PLAIN };
                return c;
            }
        }
        return null;
    }
}
