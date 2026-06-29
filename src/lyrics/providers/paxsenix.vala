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

    private PaxSenixResult[] paxsenix_score (PaxSenixResult[] results,
                                              string title, string artist,
                                              int duration_ms) {
        var cleanup_re_str = "\\s*\\(.*?\\)|\\s*\\[.*?\\]";
        Regex? cleanup_re = null;
        try { cleanup_re = new Regex (cleanup_re_str); } catch (RegexError e) {}

        var clean_title  = cleanup_re != null ? ((!)cleanup_re).replace (title, -1, 0, "").down ().strip ()
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
                if (diff <= 2000)       score += 100.0;
                else if (diff <= 5000)  score += 50.0;
                else if (diff <= 10000) score += 10.0;
                else                    score -= 50.0;
            }

            var result_clean = cleanup_re != null
                ? ((!)cleanup_re).replace (r.display_name, -1, 0, "").down ().strip ()
                : r.display_name.down ().strip ();
            if (result_clean == clean_title)
                score += 80.0;
            else if (result_clean.contains (clean_title) || clean_title.contains (result_clean))
                score += 40.0;

            bool result_is_remix = r.display_name.down ().contains ("remix");
            bool result_is_mixed = r.display_name.down ().contains ("mixed");
            if (result_is_remix && !target_is_remix) score -= 40.0;
            if (result_is_mixed && !target_is_mixed) score -= 60.0;

            var result_artist_lower = r.display_artist.down ();
            if (result_artist_lower.contains (clean_artist)) {
                score += 50.0;
            } else {
                foreach (var word in clean_artist.split (" ")) {
                    if (word.length > 2 && result_artist_lower.contains (word)) {
                        score += 25.0;
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

    private async PaxSenixResult[] paxsenix_search_itunes (string query) {
        var url = "https://itunes.apple.com/search?term=%s&limit=5&entity=song".printf (
            Uri.escape_string (query, null, false));
        string[,] headers = { { "User-Agent", "Semitone/1.0" } };
        var body = yield lyrics_http_get (url);
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
            lyrics_log ("PaxSenix: iTunes search parse error: %s".printf (e.message));
        }
        return results;
    }

    private async PaxSenixResult[] paxsenix_search_spotify (string query) {
        var url = "https://lyrics.paxsenix.org/spotify/search?q=%s".printf (
            Uri.escape_string (query, null, false));
        string[,] headers = { { "User-Agent", "Semitone/1.0" } };
        var body = yield lyrics_http_get_with_headers (url, headers);
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
            lyrics_log ("PaxSenix: Spotify search parse error: %s".printf (e.message));
        }
        return results;
    }

    private async string? paxsenix_fetch_track (string id) {
        var url = "https://lyrics.paxsenix.org/apple-music/lyrics?id=%s".printf (
            Uri.escape_string (id, null, false));
        string[,] headers = { { "User-Agent", "Semitone/1.0" } };
        var body = yield lyrics_http_get_with_headers (url, headers);
        if (body == null) return null;

        try {
            var parser = new Json.Parser ();
            parser.load_from_data ((!)body);
            var root_obj = parser.get_root ()?.get_object ();
            if (root_obj == null) return null;
            var obj = (!)root_obj;

            if (obj.has_member ("ttmlContent")) {
                var ttml = obj.get_string_member ("ttmlContent");
                if (ttml.length > 0) {
                    if (lyrics_debug_enabled) {
                        int ttml_log_len = ttml.length > 3000 ? 3000 : ttml.length;
                        lyrics_log ("PaxSenix: ttmlContent (first %d chars):\n%s".printf (ttml_log_len, ttml.substring (0, ttml_log_len)));
                    }
                    lyrics_log ("PaxSenix: using ttmlContent");
                    return ttml;
                }
            }

            if (obj.has_member ("elrcMultiPerson")) {
                var elrc = obj.get_string_member ("elrcMultiPerson");
                if (elrc.length > 0) {
                    lyrics_log ("PaxSenix: using elrcMultiPerson");
                    return elrc;
                }
            }

            if (obj.has_member ("elrc")) {
                var elrc = obj.get_string_member ("elrc");
                if (elrc.length > 0) {
                    lyrics_log ("PaxSenix: using elrc");
                    return elrc;
                }
            }

            if (obj.has_member ("lrc")) {
                var lrc = obj.get_string_member ("lrc");
                if (lrc.length > 0) {
                    lyrics_log ("PaxSenix: using lrc");
                    return lrc;
                }
            }

            if (obj.has_member ("plain")) {
                var plain = obj.get_string_member ("plain");
                if (plain.length > 0) {
                    lyrics_log ("PaxSenix: using plain fallback");
                    return plain;
                }
            }

            return null;
        } catch (Error e) {
            lyrics_log ("PaxSenix fetch_track parse error: %s".printf (e.message));
            return null;
        }
    }

    public async LyricsCandidate? provider_fetch_paxsenix (Music music, int duration_ms, Settings settings, int index) {
        if (!settings.get_boolean ("lyrics-paxsenix-enabled")) {
            lyrics_log ("PaxSenix: disabled");
            return null;
        }

        var clean_title  = paxsenix_clean_title (music.title);
        var clean_artist = paxsenix_clean_artist (music.artist);

        lyrics_log ("PaxSenix: title='%s' artist='%s' dur=%dms".printf (
            clean_title, clean_artist, duration_ms));

        string[] queries = {
            "%s %s".printf (clean_title, clean_artist)
        };
        if (music.album.length > 0)
            queries += "%s %s %s".printf (clean_title, clean_artist, music.album);

        // ── Try iTunes Search first (gets Apple Music track IDs) ──
        PaxSenixResult[] scored = {};
        foreach (var query in queries) {
            if (scored.length > 0) break;
            lyrics_log ("PaxSenix: searching iTunes '%s'".printf (query));
            var raw_results = yield paxsenix_search_itunes (query);
            if (raw_results.length > 0)
                scored = paxsenix_score (raw_results, music.title, music.artist, duration_ms);
        }

        // ── Fall back to Spotify search if iTunes returned nothing ──
        if (scored.length == 0) {
            foreach (var query in queries) {
                if (scored.length > 0) break;
                lyrics_log ("PaxSenix: searching Spotify '%s'".printf (query));
                var raw_results = yield paxsenix_search_spotify (query);
                if (raw_results.length > 0)
                    scored = paxsenix_score (raw_results, music.title, music.artist, duration_ms);
            }
        }

        if (scored.length == 0) {
            lyrics_log ("PaxSenix: no search results");
            return null;
        }

        lyrics_log ("PaxSenix: %d scored results, trying top 3".printf (scored.length));

        string? plain_fallback = null;
        var limit = int.min (3, scored.length);
        for (var i = 0; i < limit; i++) {
            var r = scored[i];
            lyrics_log ("PaxSenix: trying id=%s '%s' by '%s' (score=%.1f)".printf (
                r.id, r.display_name, r.display_artist, r.score));
            var lrc = yield paxsenix_fetch_track (r.id);
            if (lrc == null) continue;

            bool has_word_timing = ((!)lrc).contains ("<tt")
                || ((!)lrc).contains ("<body")
                || (((!)lrc).contains ("<") && ((!)lrc).contains (":") && ((!)lrc).contains (">"));

            if (has_word_timing) {
                lyrics_log ("PaxSenix: word-timed result from '%s'".printf (r.display_name));
                return lyrics_build_candidate ((!)lrc, "PaxSenix", index);
            }

            if (plain_fallback == null)
                plain_fallback = lrc;
        }

        if (plain_fallback != null) {
            lyrics_log ("PaxSenix: no word-timed result, using plain fallback");
            return lyrics_build_candidate ((!)plain_fallback, "PaxSenix", index);
        }

        lyrics_log ("PaxSenix: all candidates returned null");
        return null;
    }

}
