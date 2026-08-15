namespace G4 {

    private string paxsenix_clean_title (string title) {
        string cleaned = title.strip ();
        string[] patterns = {
            "\\s*\\(.*?(?:official|video|audio|lyrics?|visualizer|hd|hq|4k|remaster|remix|live|acoustic|version|edit|extended|radio|clean|explicit).*?\\)",
            "\\s*\\[.*?(?:official|video|audio|lyrics?|visualizer|hd|hq|4k|remaster|remix|live|acoustic|version|edit|extended|radio|clean|explicit).*?\\]",
            "\\s*\\|.*$",
            "\\s*-\\s*(?:official|video|audio|lyrics?|visualizer).*$",
            "\\s*\\(feat\\..*?\\)",
            "\\s*\\(ft\\..*?\\)",
            "\\s*feat\\..*$",
            "\\s*ft\\..*$",
            "\\s*\\([^)]*\\d{4}[^)]*\\)"
        };
        foreach (var pattern in patterns) {
            try {
                var re = new Regex (pattern, RegexCompileFlags.CASELESS);
                cleaned = re.replace (cleaned, -1, 0, "");
            } catch (RegexError e) {}
        }
        return cleaned.strip ();
    }

    private string paxsenix_clean_artist (string artist) {
        string[] separators = { " & ", " and ", ", ", " x ", " X ", " feat. ", " feat ",
                                " ft. ", " ft ", " featuring ", " with " };
        var cleaned = artist.strip ();
        foreach (var sep in separators) {
            var lower = cleaned.down ();
            var sep_lower = sep.down ();
            var idx = lower.index_of (sep_lower);
            if (idx >= 0) {
                cleaned = cleaned.substring (0, idx);
                break;
            }
        }
        return cleaned.strip ();
    }

    private string regex_replace_or (Regex re, string input, string replacement, string fallback) {
        try {
            return re.replace (input, -1, 0, replacement);
        } catch (RegexError e) {
            return fallback;
        }
    }

    private PaxSenixResult[] paxsenix_score (PaxSenixResult[] results,
                                              string title, string artist,
                                              int duration_ms) {
        var cleanup_re_str = "\\s*\\(.*?\\)|\\s*\\[.*?\\]";
        Regex? cleanup_re = null;
        try { cleanup_re = new Regex (cleanup_re_str); } catch (RegexError e) {}

        var clean_title  = cleanup_re != null
            ? regex_replace_or ((!)cleanup_re, title, "", title).down ().strip ()
            : title.down ().strip ();
        var clean_artist = paxsenix_clean_artist (artist).down ();
        bool target_is_remix = title.down ().contains ("remix");
        bool target_is_mixed = title.down ().contains ("mixed");

        PaxSenixResult[] scored = results;
        for (var i = 0; i < scored.length; i++) {
            double score = 0.0;
            var r = scored[i];

            if (r.duration_ms > 0) {
                var diff = (r.duration_ms - duration_ms).abs ();
                if (diff <= 2000)       score += 30.0;
                else if (diff <= 5000)  score += 15.0;
                else if (diff <= 10000) score += 5.0;
                else                    score -= 30.0;
            }

            var result_clean = cleanup_re != null
                ? regex_replace_or ((!)cleanup_re, r.display_name, "", r.display_name).down ().strip ()
                : r.display_name.down ().strip ();
            if (result_clean == clean_title)
                score += 90.0;
            else if (result_clean.contains (clean_title) || clean_title.contains (result_clean))
                score += 45.0;

            bool result_is_remix = r.display_name.down ().contains ("remix");
            bool result_is_mixed = r.display_name.down ().contains ("mixed");
            if (result_is_remix && !target_is_remix) score -= 40.0;
            if (result_is_mixed && !target_is_mixed) score -= 60.0;

            var result_artist_lower = r.display_artist.down ();
            if (result_artist_lower.contains (clean_artist)) {
                score += 60.0;
            } else {
                foreach (var word in clean_artist.split (" ")) {
                    if (word.length > 2 && result_artist_lower.contains (word)) {
                        score += 30.0;
                        break;
                    }
                }
            }

            scored[i].score = score;
        }

        for (var i = 1; i < scored.length; i++) {
            var key = scored[i];
            var j = i - 1;
            while (j >= 0 && scored[j].score < key.score) {
                scored[j + 1] = scored[j];
                j--;
            }
            scored[j + 1] = key;
        }

        PaxSenixResult[] filtered = {};
        foreach (var r in scored)
            if (r.score > 0) filtered += r;

        return filtered;
    }

    private async PaxSenixResult[] paxsenix_search_itunes (string query, GLib.Cancellable? cancellable = null) {
        var url = "https://itunes.apple.com/search?term=%s&limit=5&entity=song".printf (
            Uri.escape_string (query, null, false));
        var body = yield lyrics_http_get (url, cancellable);
        if (cancellable != null && ((!)cancellable).is_cancelled ()) return {};
        if (body == null) return {};

        PaxSenixResult[] results = {};
        try {
            var parser = new Json.Parser ();
            parser.load_from_data ((!)body);
            var root = parser.get_root ()?.get_object ();
            if (root == null) return {};
            var obj = (!)root;
            if (!obj.has_member ("results")) return {};
            var arr = obj.get_array_member ("results");
            ((!)arr).foreach_element ((a, i, node) => {
                var result_obj = node.get_object ();
                if (result_obj == null) return;
                var r = (!)result_obj;
                var id          = r.has_member ("trackId")         ? "%lld".printf (r.get_int_member ("trackId")) : "";
                var disp_name   = r.has_member ("trackName")       ? r.get_string_member ("trackName")            : "";
                var disp_artist = r.has_member ("artistName")      ? r.get_string_member ("artistName")           : "";
                int dur_ms      = r.has_member ("trackTimeMillis") ? (int) r.get_int_member ("trackTimeMillis")   : 0;
                if (id.length > 0) {
                    PaxSenixResult sr = { id, disp_name, disp_artist, dur_ms, 0.0 };
                    results += sr;
                }
            });
        } catch (Error e) {
        }
        return results;
    }

    private async PaxSenixResult[] paxsenix_search_spotify (string query, GLib.Cancellable? cancellable = null) {
        var url = "https://lyrics.paxsenix.org/spotify/search?q=%s".printf (
            Uri.escape_string (query, null, false));
        string[,] headers = { { "User-Agent", "Semitone/1.0" } };
        var body = yield lyrics_http_get_with_headers (url, headers, cancellable);
        if (cancellable != null && ((!)cancellable).is_cancelled ()) return {};
        if (body == null) return {};

        PaxSenixResult[] results = {};
        try {
            var parser = new Json.Parser ();
            parser.load_from_data ((!)body);
            var arr = parser.get_root ()?.get_array ();
            if (arr == null) return {};
            ((!)arr).foreach_element ((a, i, node) => {
                var obj = node.get_object ();
                if (obj == null) return;
                var o = (!)obj;
                var id          = o.has_member ("trackId")       ? o.get_string_member ("trackId")        : "";
                var disp_name   = o.has_member ("name")          ? o.get_string_member ("name")           : "";
                var disp_artist = o.has_member ("artistName")    ? o.get_string_member ("artistName")     : "";
                int dur_ms      = 0;
                if (o.has_member ("duration")) {
                    var dur_str = o.get_string_member ("duration");
                    var parts = dur_str.split (":");
                    if (parts.length == 2)
                        dur_ms = (int.parse (parts[0]) * 60 + int.parse (parts[1])) * 1000;
                }
                if (id.length > 0) {
                    PaxSenixResult r = { id, disp_name, disp_artist, dur_ms, 0.0 };
                    results += r;
                }
            });
        } catch (Error e) {
        }
        return results;
    }

    private async string? paxsenix_fetch_track (string id, GLib.Cancellable? cancellable = null) {
        var url = "https://lyrics.paxsenix.org/apple-music/lyrics?id=%s".printf (
            Uri.escape_string (id, null, false));
        string[,] headers = { { "User-Agent", "Semitone/1.0" } };
        var body = yield lyrics_http_get_with_headers (url, headers, cancellable);
        if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
        if (body == null) return null;

        try {
            var parser = new Json.Parser ();
            parser.load_from_data ((!)body);
            var root_obj = parser.get_root ()?.get_object ();
            if (root_obj == null) return null;
            var obj = (!)root_obj;

            if (obj.has_member ("ttmlContent")) {
                var ttml = obj.get_string_member ("ttmlContent");
                if (ttml.length > 0) return ttml;
            }
            if (obj.has_member ("elrcMultiPerson")) {
                var elrc = obj.get_string_member ("elrcMultiPerson");
                if (elrc.length > 0) return elrc;
            }
            if (obj.has_member ("elrc")) {
                var elrc = obj.get_string_member ("elrc");
                if (elrc.length > 0) return elrc;
            }
            if (obj.has_member ("lrc")) {
                var lrc = obj.get_string_member ("lrc");
                if (lrc.length > 0) return lrc;
            }
            if (obj.has_member ("plain")) {
                var plain = obj.get_string_member ("plain");
                if (plain.length > 0) return plain;
            }
            return null;
        } catch (Error e) {
            return null;
        }
    }

    public async LyricsCandidate? provider_fetch_paxsenix (Music music, int duration_ms, Settings settings, int index, GLib.Cancellable? cancellable = null) {
        if (!settings.get_boolean ("lyrics-paxsenix-enabled")) {
            lyrics_log ("PaxSenix: disable");
            return null;
        }

        var clean_title  = paxsenix_clean_title (music.title);
        var clean_artist = paxsenix_clean_artist (music.artist);

        string[] queries = {
            "%s %s".printf (clean_title, clean_artist)
        };
        if (music.album.length > 0)
            queries += "%s %s %s".printf (clean_title, clean_artist, music.album);

        PaxSenixResult[] scored = {};
        foreach (var query in queries) {
            if (scored.length > 0) break;
            var raw_results = yield paxsenix_search_itunes (query, cancellable);
            if (raw_results.length > 0)
                scored = paxsenix_score (raw_results, music.title, music.artist, duration_ms);
        }

        if (scored.length == 0) {
            foreach (var query in queries) {
                if (scored.length > 0) break;
                var raw_results = yield paxsenix_search_spotify (query, cancellable);
                if (raw_results.length > 0)
                    scored = paxsenix_score (raw_results, music.title, music.artist, duration_ms);
            }
        }

        if (scored.length == 0)
            return null;

        string? best_word_lrc = null;
        double best_word_match = 0.0;
        string? best_line_lrc = null;
        double best_line_match = 0.0;
        // Inspect ALL returned candidates (iTunes caps the search at limit=5), not
        // just the top 3, so a word-synced match that ranks 4th/5th is not missed
        // (common for niche artists with multiple same-named acts). The confident
        // early-return below keeps the common path at a single fetch.
        for (var i = 0; i < scored.length; i++) {
            var r = scored[i];
            var lrc = yield paxsenix_fetch_track (r.id, cancellable);
            if (lrc == null) continue;

            bool has_word_timing = ((!)lrc).contains ("<tt")
                || ((!)lrc).contains ("<body")
                || (((!)lrc).contains ("<") && ((!)lrc).contains (":") && ((!)lrc).contains (">"));

            if (has_word_timing) {
                if (best_word_lrc == null || r.score > best_word_match) {
                    best_word_lrc = lrc;
                    best_word_match = r.score;
                }
                if (r.score >= 150)
                    return lyrics_build_candidate ((!)lrc, "PaxSenix", index);
                continue;
            }

            if (best_line_lrc == null || r.score > best_line_match) {
                best_line_lrc = lrc;
                best_line_match = r.score;
            }
        }

        if (best_word_lrc != null)
            return lyrics_build_candidate ((!)best_word_lrc, "PaxSenix", index);

        if (best_line_lrc != null)
            return lyrics_build_candidate ((!)best_line_lrc, "PaxSenix", index);

        return null;
    }

}
