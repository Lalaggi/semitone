namespace G4 {

    public struct LyricWord {
        public string text;
        public double start_sec;
        public double end_sec;
    }

    public struct LyricLine {
        public int64 time_ms;
        public string text;
        public LyricWord[] words;
        public string voice_role;
    }

    public struct LyricsCandidate {
        public string raw;
        public string provider;
        public LyricLine[] lines;
        public bool is_synced;
        public double score;
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

    public void lyrics_log (string msg) {
        GLib.message ("[Lyrics] %s", msg);
    }
}
