namespace G4 {

    public struct LyricsProviderInfo {
        public string id;
        public string display_name;
        public string subtitle;
    }

    public const LyricsProviderInfo[] LYRICS_PROVIDERS = {
        { "local",        "Local",          "Local .lrc, .ttml, or .lrcplus files next to the song" },
        { "musicbrainz",  "MusicBrainz",    "Instrumental detection only, provides no lyrics" },
        { "lrc-red",      "LRC.red",        "Lyrics aggregator across multiple sources with their own ranked database providing the best results" },
        { "unison",       "Unison",         "Community-sourced synced TTML from the BetterLyrics community — generally quite good, but quality is not guaranteed" },
        { "betterlyrics", "BetterLyrics",   "Best word-timed lyrics, aggregated from many sources" },
        { "lrclib",       "LRCLib",         "Crowdsourced synced and plain lyrics" },
        { "netease",      "NetEase",        "Synced lyrics from NetEase Music — great for CJK songs" },
        { "kugou",        "KuGou",          "Synced lyrics from KuGou — great for CJK songs" },
        { "paxsenix",     "Lyrically",      "High-quality synced lyrics via Apple Music (Lyrically API by Paxsenix)" },
        { "lyricsplus-apple",   "Apple Music - LyricsPlus",   "Synced lyrics from Apple Music via LyricsPlus" },
        { "lyricsplus-qq",      "QQ - LyricsPlus",            "Synced lyrics from QQ Music via LyricsPlus" },
        { "lyricsplus-deezer",  "Deezer - LyricsPlus",        "Synced lyrics from Deezer via LyricsPlus" },
        { "lyricsplus-musixmatch", "MusixMatch - LyricsPlus", "Synced lyrics from Musixmatch via LyricsPlus" },
        { "simpmusic",    "SimpMusic",      "Word-timed lyrics for YouTube Music tracks (needs YouTube ID in tags)" },
        { "megalobiz",    "Megalobiz",      "Plain lyrics via web scraping (no timing)" },
        { "genius",       "Genius",         "Plain lyrics via web scraping (no timing)" },
        { "musixmatch",   "Musixmatch",     "Plain lyrics (requires API key)" },
    };

    public const string DEFAULT_PROVIDER_ORDER =
        "local,musicbrainz,lrc-red,unison,betterlyrics,lrclib,netease,kugou,paxsenix,lyricsplus-apple,lyricsplus-qq,lyricsplus-deezer,lyricsplus-musixmatch,simpmusic,megalobiz,genius,musixmatch";

    public async LyricsCandidate? provider_fetch_local (Music music, int duration_ms, Settings settings, int index, GLib.Cancellable? cancellable = null) {
        if (!settings.get_boolean ("lyrics-local-enabled")) return null;

        LyricsCandidate? best = null;
        double best_score = -1.0;
        foreach (var lyric_file in lyrics_find_local_files (music)) {
            if (cancellable != null && ((!)cancellable).is_cancelled ()) break;
            string raw;
            if (!lyrics_read_local_file (lyric_file, out raw)) continue;

            var candidate = lyrics_build_candidate (raw, "Local", index);
            if (candidate == null) continue;

            var c = (!)candidate;
            c.local_path = lyric_file.get_path () ?? lyric_file.get_uri ();
            // Same provider index for every sibling file: format quality and
            // completion decide, with LRC+ winning ties (see file order).
            if (c.score > best_score + 0.001) {
                best = c;
                best_score = c.score;
            }
        }
        return best;
    }

    public async LyricsCandidate? lyrics_fetch_provider (string id, Music music, int duration_ms, Settings settings, int index, GLib.Cancellable? cancellable = null) {
        switch (id) {
            case "local":        return yield provider_fetch_local (music, duration_ms, settings, index, cancellable);
            case "musicbrainz":  return yield provider_fetch_musicbrainz (music, duration_ms, settings, index, cancellable);
            case "lrc-red":      return yield provider_fetch_lrc_red (music, duration_ms, settings, index, cancellable);
            case "unison":       return yield provider_fetch_unison (music, duration_ms, settings, index, cancellable);
            case "betterlyrics": return yield provider_fetch_betterlyrics (music, duration_ms, settings, index, cancellable);
            case "lrclib":       return yield provider_fetch_lrclib (music, duration_ms, settings, index, cancellable);
            case "netease":      return yield provider_fetch_netease (music, duration_ms, settings, index, cancellable);
            case "kugou":        return yield provider_fetch_kugou (music, duration_ms, settings, index, cancellable);
            case "paxsenix":     return yield provider_fetch_paxsenix (music, duration_ms, settings, index, cancellable);
            case "lyricsplus-apple":   return yield provider_fetch_lyricsplus_apple (music, duration_ms, settings, index, cancellable);
            case "lyricsplus-qq":      return yield provider_fetch_lyricsplus_qq (music, duration_ms, settings, index, cancellable);
            case "lyricsplus-deezer":  return yield provider_fetch_lyricsplus_deezer (music, duration_ms, settings, index, cancellable);
            case "lyricsplus-musixmatch": return yield provider_fetch_lyricsplus_musixmatch (music, duration_ms, settings, index, cancellable);
            case "simpmusic":    return yield provider_fetch_simpmusic (music, duration_ms, settings, index, cancellable);
            case "megalobiz":    return yield provider_fetch_megalobiz (music, duration_ms, settings, index, cancellable);
            case "genius":       return yield provider_fetch_genius (music, duration_ms, settings, index, cancellable);
            case "musixmatch":   return yield provider_fetch_musixmatch (music, duration_ms, settings, index, cancellable);
            default: return null;
        }
    }
}
