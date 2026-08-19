namespace G4 {

    public async LyricsCandidate? provider_fetch_betterlyrics (Music music, int duration_ms, Settings settings, int index, GLib.Cancellable? cancellable = null) {
        if (!settings.get_boolean ("lyrics-betterlyrics-enabled")) {
            lyrics_log ("BetterLyrics: disable");
            return null;
        }

        var duration_sec = (int) (duration_ms / 1000);
        var url = "https://lyrics-api.boidu.dev/getLyrics?s=%s&a=%s&al=%s&d=%d".printf (
            Uri.escape_string (music.title, null, false),
            Uri.escape_string (music.artist, null, false),
            Uri.escape_string (music.album, null, false),
            duration_sec);
        var api_key = read_api_key_file ("betterlyrics-api-key");
        string[,] headers = {
            { "User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" },
            { "Accept", "application/json" }
        };
        if (api_key != null) {
            string[,] new_headers = {
                { "User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" },
                { "Accept", "application/json" },
                { "X-API-Key", (!)api_key }
            };
            headers = new_headers;
        }
        var body = yield lyrics_http_get_with_headers_allow_4xx (url, headers, cancellable);
        if (body == null) return null;
        try {
            var parser = new Json.Parser ();
            parser.load_from_data ((!)body);
            var root_obj = parser.get_root ()?.get_object ();
            if (root_obj == null) return null;
            var obj = (!)root_obj;
            if (obj.has_member ("error")) {
                if (lyrics_debug_enabled)
                    lyrics_log ("BetterLyrics: %s".printf (obj.get_string_member ("error")));
                return null;
            }
            if (obj.has_member ("ttml")) {
                var ttml = obj.get_string_member ("ttml");
                if (ttml.length > 0)
                    return lyrics_build_candidate (ttml, "BetterLyrics", index);
                return null;
            }
            if (obj.has_member ("lyrics")) {
                var raw = obj.get_string_member ("lyrics");
                return lyrics_build_candidate (raw, "BetterLyrics", index);
            }
            return null;
        } catch (Error e) {
            if (lyrics_debug_enabled)
                lyrics_log ("BetterLyrics: %s".printf (e.message));
            return null;
        }
    }
}
