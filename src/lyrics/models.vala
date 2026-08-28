namespace G4 {

    public struct LyricWord {
        public string text;
        public double start_sec;
        public double end_sec;
        public string style;
        public string effect;
    }

    public struct LyricLine {
        public int64 time_ms;
        public string text;
        public LyricWord[] words;
        public string voice_role;
        public string style;
        public string effect;
        public string lang;
    }

    public struct LyricsCandidate {
        public string raw;
        public string provider;
        public LyricLine[] lines;
        public bool is_synced;
        public double score;
        public LyricsFormat format;
    }

    public struct LrclibResult {
        public string synced;
        public string plain;
        public bool instrumental;
    }

    public struct PaxSenixResult {
        public string id;
        public string display_name;
        public string display_artist;
        public int duration_ms;
        public double score;
    }

    public enum LyricsFormat {
        PLAIN,
        LRC,
        LRC_PLUS,
        EXTENDED_LRC,
        TTML_WORD_SYNCED,
        TTML_LINE_SYNCED,
        TTML_UNSYNCED
    }

    public static bool lyrics_debug_enabled = false;

    public string lyrics_format_source (LyricsFormat format) {
        switch (format) {
            case LyricsFormat.TTML_WORD_SYNCED: return "ttml-word";
            case LyricsFormat.TTML_LINE_SYNCED: return "ttml-line";
            case LyricsFormat.TTML_UNSYNCED:    return "ttml";
            case LyricsFormat.LRC_PLUS:         return "lrc+";
            case LyricsFormat.EXTENDED_LRC:     return "elrc";
            case LyricsFormat.LRC:              return "lrc";
            case LyricsFormat.PLAIN:
            default:                            return "plain";
        }
    }

    public string lyrics_format_synced (LyricsFormat format) {
        switch (format) {
            case LyricsFormat.TTML_WORD_SYNCED:
            case LyricsFormat.LRC_PLUS:
            case LyricsFormat.EXTENDED_LRC:
                return "Word";
            case LyricsFormat.TTML_LINE_SYNCED:
            case LyricsFormat.LRC:
                return "Line";
            default:
                return "None";
        }
    }

    public void lyrics_log (string msg) {
        GLib.message ("[Lyrics] %s", msg);
    }
}
