namespace G4 {

    private const string UNISON_BASE_URL = "https://unison.boidu.dev";
    // Metadata-search hits are unverified (Unison ranks by community votes, so a
    // popular wrong song can outrank the right one). Penalize them so a matching
    // result from another provider beats an unverified Unison match.
    private const double UNISON_UNVERIFIED_PENALTY = 0.85;

    internal string unison_get_string_member (Json.Object obj, string name) {
        if (!obj.has_member (name)) return "";
        var node = obj.get_member (name);
        if (node == null || ((!)node).get_node_type () != Json.NodeType.VALUE) return "";
        var val = ((!)node).get_string ();
        return val ?? "";
    }

    internal string unison_normalize_text (string s) {
        var lower = s.down ().strip ();
        // Drop (...) and [...] segments (versions, feats, etc.)
        try {
            var re = new Regex ("\\s*[\\(\\[].*?[\\)\\]]");
            lower = re.replace (lower, -1, 0, "");
        } catch (RegexError e) {}
        // Keep letters (Unicode-aware, so CJK survives), numbers and spaces
        var sb = new StringBuilder ();
        var pos = 0;
        unichar c;
        while (lower.get_next_char (ref pos, out c)) {
            if (c.isalnum () || c == ' ')
                sb.append_unichar (c);
        }
        // Collapse whitespace
        try {
            var re_ws = new Regex ("\\s+");
            return re_ws.replace (sb.str, -1, 0, " ").strip ();
        } catch (RegexError e) {
            return sb.str.strip ();
        }
    }

    internal bool unison_text_matches (string a, string b) {
        var na = unison_normalize_text (a);
        var nb = unison_normalize_text (b);
        if (na.length == 0 || nb.length == 0) return false;
        return na == nb || na.contains (nb) || nb.contains (na);
    }

    // A record is only usable if its song AND artist match the query. This
    // rejects popular-but-wrong top hits (e.g. another song with more votes).
    internal bool unison_record_matches (Json.Object data, string song, string artist) {
        string record_song = unison_get_string_member (data, "song");
        string record_artist = unison_get_string_member (data, "artist");
        if (record_song.length == 0 || record_artist.length == 0) return false;
        bool ok = unison_text_matches (record_song, song) && unison_text_matches (record_artist, artist);
        if (!ok && lyrics_debug_enabled)
            lyrics_log ("Unison: skipping '%s' by '%s' (query '%s' / '%s')".printf (
                record_song, record_artist, song, artist));
        return ok;
    }

    private LyricsCandidate? unison_build_from_data (Json.Object data, int index) {
        string lyrics = unison_get_string_member (data, "lyrics");
        if (lyrics.strip ().length == 0) return null;
        return lyrics_build_candidate (lyrics, "Unison", index);
    }

    // Build a candidate from a metadata-search record: requires song/artist
    // verification and applies the unverified-match penalty.
    private LyricsCandidate? unison_build_verified (Json.Object data, string song, string artist, int index) {
        if (!unison_record_matches (data, song, artist)) return null;
        var c = unison_build_from_data (data, index);
        if (c == null) return null;
        var verified = (!)c;
        verified.score *= UNISON_UNVERIFIED_PENALTY;
        return verified;
    }

    private Json.Object? unison_parse_envelope_data (string? body) {
        if (body == null) return null;
        try {
            var parser = new Json.Parser ();
            parser.load_from_data ((!)body);
            var root = parser.get_root ()?.get_object ();
            if (root == null) return null;
            var obj = (!)root;
            if (obj.has_member ("success") && !obj.get_boolean_member ("success")) return null;
            if (!obj.has_member ("data")) return null;
            return obj.get_object_member ("data");
        } catch (Error e) {
            return null;
        }
    }

    private Json.Array? unison_parse_envelope_array (string? body) {
        if (body == null) return null;
        try {
            var parser = new Json.Parser ();
            parser.load_from_data ((!)body);
            var root = parser.get_root ()?.get_object ();
            if (root == null) return null;
            var obj = (!)root;
            if (obj.has_member ("success") && !obj.get_boolean_member ("success")) return null;
            if (!obj.has_member ("data")) return null;
            return obj.get_array_member ("data");
        } catch (Error e) {
            return null;
        }
    }

    // Exact hit by YouTube video ID (same lookup the Better Lyrics extension
    // does). The video IS the song, so no verification or penalty needed.
    private async LyricsCandidate? unison_fetch_by_video (string video_id, string song, string artist, string album, int duration_sec, int index, GLib.Cancellable? cancellable) {
        var url = "%s/lyrics?v=%s&song=%s&artist=%s".printf (
            UNISON_BASE_URL,
            Uri.escape_string (video_id, null, false),
            Uri.escape_string (song, null, false),
            Uri.escape_string (artist, null, false));
        if (album.length > 0)
            url += "&album=%s".printf (Uri.escape_string (album, null, false));
        if (duration_sec > 0)
            url += "&duration=%d".printf (duration_sec);
        var body = yield lyrics_http_get (url, cancellable);
        if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
        var data = unison_parse_envelope_data (body);
        if (data == null) return null;
        return unison_build_from_data ((!)data, index);
    }

    private async LyricsCandidate? unison_fetch_direct (string song, string artist, string album, int duration_sec, int index, GLib.Cancellable? cancellable) {
        var url = "%s/lyrics?song=%s&artist=%s".printf (
            UNISON_BASE_URL,
            Uri.escape_string (song, null, false),
            Uri.escape_string (artist, null, false));
        if (album.length > 0)
            url += "&album=%s".printf (Uri.escape_string (album, null, false));
        if (duration_sec > 0)
            url += "&duration=%d".printf (duration_sec);
        var body = yield lyrics_http_get (url, cancellable);
        if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
        var data = unison_parse_envelope_data (body);
        if (data == null) return null;
        return unison_build_verified ((!)data, song, artist, index);
    }

    private async LyricsCandidate? unison_fetch_search_exact (string song, string artist, string album, int duration_sec, int index, GLib.Cancellable? cancellable) {
        var url = "%s/lyrics/search?song=%s&artist=%s&limit=5".printf (
            UNISON_BASE_URL,
            Uri.escape_string (song, null, false),
            Uri.escape_string (artist, null, false));
        if (album.length > 0)
            url += "&album=%s".printf (Uri.escape_string (album, null, false));
        if (duration_sec > 0)
            url += "&duration=%d".printf (duration_sec);
        var body = yield lyrics_http_get (url, cancellable);
        if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
        var arr = unison_parse_envelope_array (body);
        if (arr == null) return null;
        LyricsCandidate? best = null;
        ((!)arr).foreach_element ((a, i, node) => {
            if (best != null) return;
            var entry = node.get_object ();
            if (entry == null) return;
            var c = unison_build_verified ((!)entry, song, artist, index);
            if (c != null) best = (!)c;
        });
        return best;
    }

    private async LyricsCandidate? unison_fetch_search_fuzzy (string song, string artist, string album, int duration_sec, int index, GLib.Cancellable? cancellable) {
        var query = "%s %s".printf (song, artist).strip ();
        if (query.length < 2) return null;
        var url = "%s/lyrics/search?q=%s&limit=5".printf (
            UNISON_BASE_URL, Uri.escape_string (query, null, false));
        var body = yield lyrics_http_get (url, cancellable);
        if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
        var arr = unison_parse_envelope_array (body);
        if (arr == null) return null;
        // q-search rows carry no lyrics body, but do carry song/artist — only
        // resolve videos whose metadata matches the query.
        string[] video_ids = {};
        ((!)arr).foreach_element ((a, i, node) => {
            var entry = node.get_object ();
            if (entry == null) return;
            var e = (!)entry;
            if (!unison_record_matches (e, song, artist)) return;
            string vid = unison_get_string_member (e, "videoId");
            if (vid.length == 0) vid = unison_get_string_member (e, "video_id");
            if (vid.length > 0) video_ids += vid;
        });
        var limit = int.min (3, video_ids.length);
        for (var i = 0; i < limit; i++) {
            if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
            var data = unison_parse_envelope_data (
                yield lyrics_http_get ("%s/lyrics?v=%s".printf (
                    UNISON_BASE_URL, Uri.escape_string (video_ids[i], null, false)), cancellable));
            if (data == null) continue;
            var c = unison_build_verified ((!)data, song, artist, index);
            if (c != null) return c;
        }
        return null;
    }

    public async LyricsCandidate? provider_fetch_unison (Music music, int duration_ms, Settings settings, int index, GLib.Cancellable? cancellable = null) {
        if (!settings.get_boolean ("lyrics-unison-enabled")) {
            lyrics_log ("Unison: disable");
            return null;
        }

        var duration_sec = (int) (duration_ms / 1000);

        // Prefer an exact hit by YouTube video ID (same IDs SimpMusic uses).
        string? yt_id = get_youtube_id_from_all_metadata (music.uri);
        if (yt_id == null)
            yt_id = extract_youtube_id (music.comment);
        if (yt_id != null) {
            var c = yield unison_fetch_by_video ((!)yt_id, music.title, music.artist, music.album, duration_sec, index, cancellable);
            if (c != null) return c;
            if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
            if (lyrics_debug_enabled)
                lyrics_log ("Unison: no hit for video %s, falling back to metadata search".printf ((!)yt_id));
        }

        var c = yield unison_fetch_direct (music.title, music.artist, music.album, duration_sec, index, cancellable);
        if (c != null) return c;
        if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;

        c = yield unison_fetch_search_exact (music.title, music.artist, music.album, duration_sec, index, cancellable);
        if (c != null) return c;
        if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;

        return yield unison_fetch_search_fuzzy (music.title, music.artist, music.album, duration_sec, index, cancellable);
    }
}
