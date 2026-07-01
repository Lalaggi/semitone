namespace G4 {

    public async LyricsCandidate? provider_fetch_lrclib (Music music, int duration_ms, Settings settings, int index, GLib.Cancellable? cancellable = null) {
        if (!settings.get_boolean ("lyrics-lrclib-enabled")) {
            lyrics_log ("LRCLib: disabled");
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
            lyrics_log ("LRCLib search: found %d results, first match instrumental=%s".printf (
                (int) arr.get_length (), instrumental.to_string ()));
            return lyrics_build_lrclib_candidate (synced_val, plain_val, instrumental, index);
        } catch (Error e) {
            lyrics_log ("LRCLib parse error: %s".printf (e.message));
            return null;
        }
    }

    private LyricsCandidate? lyrics_build_lrclib_candidate (string synced, string plain, bool instrumental, int index) {
        if (instrumental) {
            LyricsCandidate c = { "[instrumental]", "LRCLib", {}, false, 0 };
            return c;
        }
        if (synced.length > 0) {
            var parsed = parse_lrc (synced);
            if (parsed.length > 0) {
                var score = lyrics_score_candidate (parsed, true, synced, index, "LRCLib");
                lyrics_log ("LRCLib synced: %d lines, score=%.1f".printf (parsed.length, score));
                LyricsCandidate c = { synced, "LRCLib", parsed, true, score };
                return c;
            }
        }
        if (plain.length > 0) {
            var parsed = parse_plain (plain);
            if (parsed.length > 0) {
                var score = lyrics_score_candidate (parsed, false, plain, index, "LRCLib");
                lyrics_log ("LRCLib plain: %d lines, score=%.1f".printf (parsed.length, score));
                LyricsCandidate c = { plain, "LRCLib", parsed, false, score };
                return c;
            }
        }
        return null;
    }
}
