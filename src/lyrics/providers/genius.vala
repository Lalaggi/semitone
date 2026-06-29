namespace G4 {

    public async LyricsCandidate? provider_fetch_genius (Music music, int duration_ms, Settings settings, int index) {
        if (!settings.get_boolean ("lyrics-genius-enabled")) {
            lyrics_log ("Genius: disabled");
            return null;
        }

        var query = Uri.escape_string ("%s %s".printf (music.title, music.artist), null, false);
        var scrape_url = "https://genius.com/search?q=%s".printf (query);
        string[,] scrape_headers = {
            { "User-Agent", "Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0" }
        };
        var page = yield lyrics_http_get_with_headers (scrape_url, scrape_headers);
        if (page == null) return null;
        try {
            var re = new Regex ("href=\"(https://genius\\.com/[A-Za-z0-9-]+-lyrics)\"");
            MatchInfo info;
            if (!re.match ((!)page, 0, out info)) return null;
            string? song_url = info.fetch (1);
            if (song_url == null) return null;
            var song_page = yield lyrics_http_get_with_headers ((!)song_url, scrape_headers);
            if (song_page == null) return null;
            var lyrics_re = new Regex (
                "data-lyrics-container=\"true\"[^>]*>([^<]*(?:<(?!/?div)[^<]*)*)",
                RegexCompileFlags.DOTALL);
            MatchInfo lyrics_info;
            var sb = new StringBuilder ();
            var pos = 0;
            while (lyrics_re.match_full ((!)song_page, -1, pos, 0, out lyrics_info)) {
                var chunk = lyrics_info.fetch (1) ?? "";
                var tag_re = new Regex ("<[^>]+>");
                chunk = tag_re.replace (chunk, -1, 0, "");
                sb.append (chunk.replace ("&#x27;", "'")
                                .replace ("&amp;", "&")
                                .replace ("&quot;", "\"")
                                .replace ("&lt;", "<")
                                .replace ("&gt;", ">").strip ());
                sb.append_c ('\n');
                int match_start, match_end;
                lyrics_info.fetch_pos (0, out match_start, out match_end);
                pos = match_end;
            }
            var result = sb.str.strip ();
            bool artist_match = result.down ().contains (music.artist.down ());
            bool title_match  = result.down ().contains (music.title.down ());
            if (!artist_match && !title_match) return null;
            if (result.length == 0) return null;
            return lyrics_build_candidate (result, "Genius", index);
        } catch (RegexError e) {
            lyrics_log ("Genius regex error: %s".printf (e.message));
            return null;
        }
    }
}
