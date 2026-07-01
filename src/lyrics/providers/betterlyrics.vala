namespace G4 {

    public async LyricsCandidate? provider_fetch_betterlyrics (Music music, int duration_ms, Settings settings, int index, GLib.Cancellable? cancellable = null) {
        if (!settings.get_boolean ("lyrics-betterlyrics-enabled")) {
            lyrics_log ("BetterLyrics: disabled");
            return null;
        }

        var duration_sec = (int) (duration_ms / 1000);
        var url = "https://lyrics-api.boidu.dev/getLyrics?s=%s&a=%s&al=%s&d=%d".printf (
            Uri.escape_string (music.title, null, false),
            Uri.escape_string (music.artist, null, false),
            Uri.escape_string (music.album, null, false),
            duration_sec);
        lyrics_log ("BetterLyrics URL: %s".printf (url));
        var api_key = read_api_key_file ("betterlyrics-api-key");
        string[,] headers = {
            { "User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" },
            { "Accept", "application/json" }
        };
        if (api_key != null) {
            lyrics_log ("BetterLyrics: using API key");
            string[,] new_headers = {
                { "User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" },
                { "Accept", "application/json" },
                { "X-API-Key", (!)api_key }
            };
            headers = new_headers;
        } else {
            lyrics_log ("BetterLyrics: no API key found - create ~/.config/semitone/betterlyrics-api-key to enable");
        }
        var body = yield lyrics_http_get_with_headers_allow_4xx (url, headers, cancellable);
        int body_len = body != null ? ((!)body).length : 0;
        int log_len = body_len > 500 ? 500 : body_len;
        lyrics_log ("BetterLyrics response (len=%d): %s".printf (body_len, body != null ? ((!)body).substring (0, log_len) : "null"));
        if (body == null) return null;
        try {
            var parser = new Json.Parser ();
            parser.load_from_data ((!)body);
            var root_obj = parser.get_root ()?.get_object ();
            if (root_obj == null) return null;
            var obj = (!)root_obj;
            if (obj.has_member ("error")) {
                var err_msg = obj.get_string_member ("error");
                lyrics_log ("BetterLyrics API error: %s".printf (err_msg));
                if (err_msg.contains ("API key required")) {
                    lyrics_log ("BetterLyrics: API key required for uncached songs. Create ~/.config/semitone/betterlyrics-api-key or try a more popular song");
                }
                return null;
            }
            if (obj.has_member ("ttml")) {
                var ttml = obj.get_string_member ("ttml");
                if (ttml.length > 0) {
                    if (lyrics_debug_enabled) {
                        int ttml_log_len = ttml.length > 3000 ? 3000 : ttml.length;
                        lyrics_log ("BetterLyrics: ttml (first %d chars):\n%s".printf (ttml_log_len, ttml.substring (0, ttml_log_len)));
                    }
                    lyrics_log ("BetterLyrics: using ttml");
                    return lyrics_build_candidate (ttml, "BetterLyrics", index);
                }
                return null;
            }
            if (obj.has_member ("lyrics")) {
                var raw = obj.get_string_member ("lyrics");
                return lyrics_build_candidate (raw, "BetterLyrics", index);
            }
            return null;
        } catch (Error e) {
            lyrics_log ("BetterLyrics: JSON parse error: %s".printf (e.message));
            return null;
        }
    }
}
