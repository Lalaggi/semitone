namespace G4 {

    public struct LyricsProviderInfo {
        public string id;
        public string display_name;
        public string subtitle;
    }

    public const LyricsProviderInfo[] LYRICS_PROVIDERS = {
        { "paxsenix",    "PaxSenix",      "High-quality synced lyrics via Apple Music"                          },
        { "betterlyrics", "BetterLyrics",  "Best word-timed lyrics, aggregated from many sources"                },
        { "unison",       "Unison",         "Community-synced lyrics from BetterLyrics users — quality varies but often great" },
        { "binimum",      "BiniLyrics",     "Word-timed TTML lyrics via BiniLyrics (Apple Music archive)" },
        { "simpmusic",    "SimpMusic",      "Word-timed lyrics for YouTube Music tracks (needs YouTube ID in tags)" },
        { "lyricsplus",   "LyricsPlus",     "Synced lyrics aggregator (Apple, Spotify, Musixmatch)"               },
        { "lrclib",       "LRCLib",         "Crowdsourced synced and plain lyrics"                              },
        { "netease",      "NetEase",        "Synced lyrics from NetEase Music — great for CJK songs"            },
        { "kugou",        "KuGou",          "Synced lyrics from KuGou — great for CJK songs"                  },
        { "megalobiz",    "Megalobiz",      "Plain lyrics via web scraping (no timing)"                         },
        { "genius",       "Genius",         "Plain lyrics via web scraping (no timing)"                         },
        { "musixmatch",   "Musixmatch",     "Plain lyrics (requires API key)"                                   },
        { "musicbrainz",  "MusicBrainz",    "Instrumental detection only, provides no lyrics"                   },
    };

    public const string DEFAULT_PROVIDER_ORDER =
        "betterlyrics,unison,binimum,lrclib,paxsenix,netease,kugou,musicbrainz,simpmusic,megalobiz,lyricsplus,genius,musixmatch";

    public async LyricsCandidate? lyrics_fetch_provider (string id, Music music, int duration_ms, Settings settings, int index, GLib.Cancellable? cancellable = null) {
        switch (id) {
            case "paxsenix":    return yield provider_fetch_paxsenix (music, duration_ms, settings, index, cancellable);
            case "betterlyrics": return yield provider_fetch_betterlyrics (music, duration_ms, settings, index, cancellable);
            case "unison":       return yield provider_fetch_unison (music, duration_ms, settings, index, cancellable);
            case "binimum":      return yield provider_fetch_binimum (music, duration_ms, settings, index, cancellable);
            case "simpmusic":    return yield provider_fetch_simpmusic (music, duration_ms, settings, index, cancellable);
            case "lyricsplus":   return yield provider_fetch_lyricsplus (music, duration_ms, settings, index, cancellable);
            case "lrclib":       return yield provider_fetch_lrclib (music, duration_ms, settings, index, cancellable);
            case "netease":      return yield provider_fetch_netease (music, duration_ms, settings, index, cancellable);
            case "kugou":        return yield provider_fetch_kugou (music, duration_ms, settings, index, cancellable);
            case "megalobiz":    return yield provider_fetch_megalobiz (music, duration_ms, settings, index, cancellable);
            case "genius":       return yield provider_fetch_genius (music, duration_ms, settings, index, cancellable);
            case "musixmatch":   return yield provider_fetch_musixmatch (music, duration_ms, settings, index, cancellable);
            case "musicbrainz":  return yield provider_fetch_musicbrainz (music, duration_ms, settings, index, cancellable);
            default: return null;
        }
    }
}
