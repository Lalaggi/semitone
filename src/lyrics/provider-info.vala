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
        { "lyricsplus",   "LyricsPlus",     "Synced lyrics aggregator (Apple, Spotify, QQ, Deezer)"                },
        { "lrclib",       "LRCLib",         "Crowdsourced synced and plain lyrics"                              },
        { "netease",      "NetEase",        "Synced lyrics from NetEase Music — great for CJK songs"            },
        { "kugou",        "KuGou",          "Synced lyrics from KuGou — great for CJK songs"                  },
        { "megalobiz",    "Megalobiz",      "Plain lyrics via web scraping (no timing)"                         },
        { "genius",       "Genius",         "Plain lyrics via web scraping (no timing)"                         },
        { "musixmatch",   "Musixmatch",     "Plain lyrics (requires API key)"                                   },
        { "musicbrainz",  "MusicBrainz",    "Instrumental detection only, provides no lyrics"                   },
        { "local",        "Local",          "Load .lrc, .ttml, or .lrcplus files from the song folder"         },
    };

    public const string DEFAULT_PROVIDER_ORDER =
        "betterlyrics,unison,binimum,lrclib,paxsenix,netease,kugou,musicbrainz,simpmusic,megalobiz,lyricsplus,genius,musixmatch,local";

    public async LyricsCandidate? provider_fetch_local (Music music, int duration_ms, Settings settings, int index, GLib.Cancellable? cancellable = null) {
        if (!settings.get_boolean ("lyrics-local-enabled")) return null;
        var file = File.new_for_uri (music.uri);
        var parent = file.get_parent ();
        if (parent == null) return null;
        var basename = file.get_basename ();
        if (basename == null) return null;
        string stripped = basename ?? "";
        foreach (var ext in new string[] {".mp3",".flac",".ogg",".opus",".m4a",".wma",".wav",".aac",".alac",".dsf",".dff"}) {
            if (stripped.has_suffix (ext)) {
                stripped = stripped.substring (0, stripped.length - ext.length);
                break;
            }
        }
        foreach (var ext in new string[] {".lrc",".ttml",".lrcplus"}) {
            var lyric_path = GLib.Path.build_filename (((!)parent).get_path () ?? "", stripped + ext);
            var lyric_file = File.new_for_path (lyric_path);
            if (lyric_file.query_exists ()) {
                try {
                    uint8[] bytes;
                    string? etag = null;
                    if (lyric_file.load_contents (null, out bytes, out etag)) {
                        string raw = (string) bytes;
                        var format = detect_lyrics_format (raw);
                        var content = raw;
                        if (format != LyricsFormat.PLAIN && format != LyricsFormat.TTML_UNSYNCED
                                && lyrics_raw_has_only_zero_timestamps (raw)) {
                            content = lyrics_lrc_to_plain_text (raw);
                            format = LyricsFormat.PLAIN;
                        }
                        var parsed = parse (content, format);
                        bool is_synced = format != LyricsFormat.PLAIN && format != LyricsFormat.TTML_UNSYNCED;
                        var score = lyrics_score_candidate (parsed, format, index, "Local");
                        LyricsCandidate c = { content, "Local", parsed, is_synced, score, format };
                        return c;
                    }
                } catch (Error e) {
                    // ignore
                }
            }
        }
        return null;
    }

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
            case "local":        return yield provider_fetch_local (music, duration_ms, settings, index, cancellable);
            default: return null;
        }
    }
}
