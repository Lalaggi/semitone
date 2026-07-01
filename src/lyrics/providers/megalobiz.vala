namespace G4 {

    public async LyricsCandidate? provider_fetch_megalobiz (Music music, int duration_ms, Settings settings, int index, GLib.Cancellable? cancellable = null) {
        if (!settings.get_boolean ("lyrics-megalobiz-enabled")) {
            lyrics_log ("Megalobiz: disabled");
            return null;
        }

        var query = Uri.escape_string ("%s %s".printf (music.title, music.artist), null, false);
        var search_url = "https://www.megalobiz.com/search/all?qry=%s&display=more".printf (query);
        string[,] headers = {
            { "User-Agent", "Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0" }
        };
        var search_body = yield lyrics_http_get_with_headers (search_url, headers, cancellable);
        if (search_body == null) return null;
        try {
            var re = new Regex ("/lrc/maker/(\\d+)");
            MatchInfo info;
            if (!re.match ((!)search_body, 0, out info)) return null;
            var lrc_id = info.fetch (1);
            var lrc_url = "https://www.megalobiz.com/lrc/maker/%s".printf ((!)lrc_id);
            var lrc_body = yield lyrics_http_get_with_headers (lrc_url, headers, cancellable);
            if (lrc_body == null) return null;
            var lrc_re = new Regex (
                "<div[^>]*class=\"[^\"]*lrc[^\"]*\"[^>]*>([^<]*(?:<(?!/?div)[^<]*)*)</div>",
                RegexCompileFlags.DOTALL);
            MatchInfo lrc_info;
            if (!lrc_re.match ((!)lrc_body, 0, out lrc_info)) {
                var start = ((!)lrc_body).index_of ("[00:");
                if (start < 0) return null;
                var raw = ((!)lrc_body).substring (start, int.min (8192, ((!)lrc_body).length - start));
                return lyrics_build_candidate (raw, "Megalobiz", index);
            }
            var raw = lrc_info.fetch (1)?.strip ();
            if (raw == null || ((!)raw).length == 0) return null;
            return lyrics_build_candidate ((!)raw, "Megalobiz", index);
        } catch (RegexError e) {
            lyrics_log ("Megalobiz regex error: %s".printf (e.message));
            return null;
        }
    }
}
