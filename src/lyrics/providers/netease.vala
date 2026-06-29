namespace G4 {

    public async LyricsCandidate? provider_fetch_netease (Music music, int duration_ms, Settings settings, int index) {
        if (!settings.get_boolean ("lyrics-netease-enabled")) {
            lyrics_log ("NetEase: disabled");
            return null;
        }

        var search_url = "https://music.163.com/api/search/get?s=%s+%s&type=1&limit=1".printf (
            Uri.escape_string (music.title, null, false),
            Uri.escape_string (music.artist, null, false));
        string[,] headers = {
            { "User-Agent", "Mozilla/5.0" },
            { "Referer", "https://music.163.com" }
        };
        var search_body = yield lyrics_http_get_with_headers (search_url, headers);
        if (search_body == null) return null;
        try {
            var parser = new Json.Parser ();
            parser.load_from_data ((!)search_body);
            var root = parser.get_root ()?.get_object ();
            if (root == null) return null;
            var result = ((!)root).get_object_member ("result");
            if (result == null) return null;
            var songs = ((!)result).get_array_member ("songs");
            if (songs == null) return null;
            if (((!)songs).get_length () == 0) return null;
            var song = ((!)songs).get_object_element (0);
            var id = song.get_int_member ("id");
            var lyric_url = "https://music.163.com/api/song/lyric?id=%lld&lv=1".printf (id);
            var lyric_body = yield lyrics_http_get_with_headers (lyric_url, headers);
            if (lyric_body == null) return null;
            var parser2 = new Json.Parser ();
            parser2.load_from_data ((!)lyric_body);
            var lroot = parser2.get_root ()?.get_object ();
            if (lroot == null) return null;
            var lrc = ((!)lroot).get_object_member ("lrc");
            if (lrc == null) return null;
            var lyric = ((!)lrc).get_string_member ("lyric");
            if (lyric.strip ().length == 0) return null;
            return lyrics_build_candidate (lyric, "NetEase", index);
        } catch (Error e) {
            lyrics_log ("NetEase error: %s".printf (e.message));
            return null;
        }
    }
}
