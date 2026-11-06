namespace G4 {

    private const string LRC_RED_BASE_URL = "https://lrc.red";

    // lrc.red API terms require a User-Agent naming the app with a link and a
    // contact route. We link the project and use its issue tracker for contact.
    private string lrc_red_user_agent () {
        return "Semitone/%s (+https://gitlab.com/Lalaggi/semitone; contact: https://gitlab.com/Lalaggi/semitone/-/issues)".printf (Config.VERSION);
    }

    private struct LrcRedHit {
        public string isrc;
        public double score;
    }

    private string? lrc_red_isrc_for_music (Music music) {
        // ISRC lookup is shared with ReccoBeats: LRC.red serves lyrics for an
        // ISRC and ReccoBeats resolves audio features for the same one.
        return lyrics_isrc_for_music (music);
    }

    private async string? lrc_red_get (string path, GLib.Cancellable? cancellable) {
        string[,] headers = {
            { "User-Agent", lrc_red_user_agent () },
            { "Accept", "text/plain, application/json, */*" }
        };
        return yield lyrics_http_get_with_headers (LRC_RED_BASE_URL + path, headers, cancellable);
    }

    // Fetch the TTML (preferred) or plain LRC for an exact ISRC.
    private async LyricsCandidate? lrc_red_fetch_isrc (string isrc, int index, GLib.Cancellable? cancellable) {
        var escaped = Uri.escape_string (isrc, null, false);
        var body = yield lrc_red_get ("/s/%s.ttml".printf (escaped), cancellable);
        if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
        if (body != null && ((!)body).strip ().length > 0)
            return lyrics_build_candidate ((!)body, "LRC.red", index);

        body = yield lrc_red_get ("/s/%s.lrc".printf (escaped), cancellable);
        if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
        if (body != null && ((!)body).strip ().length > 0)
            return lyrics_build_candidate ((!)body, "LRC.red", index);
        return null;
    }

    private double lrc_red_get_double (Json.Object obj, string name, double fallback) {
        if (!obj.has_member (name)) return fallback;
        var node = obj.get_member (name);
        if (node == null || ((!)node).get_node_type () != Json.NodeType.VALUE) return fallback;
        var n = (!)node;
        var gtype = n.get_value_type ();
        if (gtype == typeof (double) || gtype == typeof (float))
            return n.get_double ();
        if (gtype == typeof (int64) || gtype == typeof (int) || gtype == typeof (long))
            return (double) n.get_int ();
        return fallback;
    }

    private async LyricsCandidate? lrc_red_search (Music music, int duration_ms, int index, GLib.Cancellable? cancellable) {
        var query = "%s %s".printf (music.title, music.artist).strip ();
        if (query.length == 0) return null;

        var body = yield lrc_red_get ("/search.json?q=%s".printf (
            Uri.escape_string (query, null, false)), cancellable);
        if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
        if (body == null) return null;

        try {
            var parser = new Json.Parser ();
            parser.load_from_data ((!)body);
            var root = parser.get_root ()?.get_object ();
            if (root == null) return null;
            var obj = (!)root;
            if (!obj.has_member ("hits")) return null;
            var arr = obj.get_array_member ("hits");
            if (arr == null) return null;

            LrcRedHit[] hits = {};
            ((!)arr).foreach_element ((a, i, node) => {
                var entry = node.get_object ();
                if (entry == null) return;
                var e = (!)entry;
                var isrc = unison_get_string_member (e, "isrc");
                if (isrc.length == 0) return;
                var title = unison_get_string_member (e, "title");
                var artist = unison_get_string_member (e, "artist");
                // Verify it's actually our song (same wrong-hit hazard as Unison)
                if (!unison_text_matches (title, music.title) || !unison_text_matches (artist, music.artist)) {
                    if (lyrics_debug_enabled)
                        lyrics_log ("LRC.red: skipping '%s' by '%s'".printf (title, artist));
                    return;
                }

                double score = 1.0;
                if (unison_normalize_text (title) == unison_normalize_text (music.title))
                    score += 2.0;
                if (unison_normalize_text (artist) == unison_normalize_text (music.artist))
                    score += 1.0;
                if (duration_ms > 0) {
                    var dur_ms = lrc_red_get_double (e, "duration", -1.0) * 1000.0;
                    if (dur_ms > 0) {
                        var diff = (dur_ms - duration_ms).abs ();
                        if (diff <= 3000)
                            score += 3.0;
                        else if (diff <= 10000)
                            score += 1.0;
                        else
                            score -= 1.0;
                    }
                }
                LrcRedHit hit = { isrc, score };
                hits += hit;
            });

            // Highest score first.
            for (var i = 1; i < hits.length; i++) {
                var key = hits[i];
                var j = i - 1;
                while (j >= 0 && hits[j].score < key.score) {
                    hits[j + 1] = hits[j];
                    j--;
                }
                hits[j + 1] = key;
            }

            var limit = int.min (3, hits.length);
            for (var i = 0; i < limit; i++) {
                if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
                var c = yield lrc_red_fetch_isrc (hits[i].isrc, index, cancellable);
                if (c != null) return c;
            }
            return null;
        } catch (Error e) {
            if (lyrics_debug_enabled)
                lyrics_log ("LRC.red: %s".printf (e.message));
            return null;
        }
    }

    public async LyricsCandidate? provider_fetch_lrc_red (Music music, int duration_ms, Settings settings, int index, GLib.Cancellable? cancellable = null) {

        // ISRC lookup is exact — prefer it when tags carry one
        var isrc = lrc_red_isrc_for_music (music);
        if (isrc != null) {
            var c = yield lrc_red_fetch_isrc ((!)isrc, index, cancellable);
            if (c != null) return c;
            if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
        }

        return yield lrc_red_search (music, duration_ms, index, cancellable);
    }
}
