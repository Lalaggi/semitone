namespace G4 {

    public struct LyricsProviderInfo {
        public string id;
        public string display_name;
        public string subtitle;
    }

    public const LyricsProviderInfo[] LYRICS_PROVIDERS = {
        { "paxsenix",    "PaxSenix",      "Synced LRC lyrics via PaxSenix"                        },
        { "betterlyrics", "BetterLyrics",  "Word-timed TTML lyrics (synced)"                    },
        { "simpmusic",    "SimpMusic",      "Word-timed lyrics for YouTube Music tracks (synced)" },
        { "lyricsplus",   "LyricsPlus",     "Synced lyrics via LyricsPlus (Apple/Musixmatch)"     },
        { "lrclib",       "LRCLib",         "Synced and plain lyrics via LRCLib"                  },
        { "netease",      "NetEase",        "Synced LRC lyrics from NetEase Music"                },
        { "megalobiz",    "Megalobiz",      "Plain text lyrics via Megalobiz (scraping)"          },
        { "genius",       "Genius",         "Plain text lyrics via Genius (scraping)"             },
        { "musixmatch",   "Musixmatch",     "Plain text lyrics (requires API key)"                },
        { "musicbrainz",  "MusicBrainz",    "Instrumental detection via MusicBrainz tags"         },
    };

    public const string DEFAULT_PROVIDER_ORDER =
        "betterlyrics,simpmusic,lyricsplus,lrclib,paxsenix,netease,megalobiz,genius,musixmatch,musicbrainz";

    public async LyricsCandidate? lyrics_fetch_provider (string id, Music music, int duration_ms, Settings settings, int index, GLib.Cancellable? cancellable = null) {
        switch (id) {
            case "paxsenix":    return yield provider_fetch_paxsenix (music, duration_ms, settings, index, cancellable);
            case "betterlyrics": return yield provider_fetch_betterlyrics (music, duration_ms, settings, index, cancellable);
            case "simpmusic":    return yield provider_fetch_simpmusic (music, duration_ms, settings, index, cancellable);
            case "lyricsplus":   return yield provider_fetch_lyricsplus (music, duration_ms, settings, index, cancellable);
            case "lrclib":       return yield provider_fetch_lrclib (music, duration_ms, settings, index, cancellable);
            case "netease":      return yield provider_fetch_netease (music, duration_ms, settings, index, cancellable);
            case "megalobiz":    return yield provider_fetch_megalobiz (music, duration_ms, settings, index, cancellable);
            case "genius":       return yield provider_fetch_genius (music, duration_ms, settings, index, cancellable);
            case "musixmatch":   return yield provider_fetch_musixmatch (music, duration_ms, settings, index, cancellable);
            case "musicbrainz":  return yield provider_fetch_musicbrainz (music, duration_ms, settings, index, cancellable);
            default: return null;
        }
    }
}
