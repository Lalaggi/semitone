namespace G4 {

    public struct LyricWord {
        public string text;
        public double start_sec;
        public double end_sec;
        public string style;
        public string effect;
        // Syllable handling: true = this unit starts a new display word
        // (preceded by a space, or first unit of the line); false = syllable
        // continuation glued to the previous unit with no space.
        // Mirrors TTML/ELRC encoding where space separates words and
        // adjacency means same word: <span>Def</span><span>y</span>.
        public bool word_start;
    }

    public struct LyricLine {
        public int64 time_ms;
        public string text;
        public LyricWord[] words;
        public string voice_role;
        public string voice_display;
        public string style;
        public string effect;
        public string lang;
        // Performer/actor credit (e.g. "Idina Menzel") while voice_display
        // holds the character/pretty name (e.g. "Elphaba"). Both are declared
        // once per file in @[...] voice-table lines, never inline.
        public string voice_credit;
        // Agent kind from the TTML head (e.g. "person" | "group") or the
        // @[id,...,type=X] table token. Lets nameless ids (v1000) render a
        // type label instead of a bare coded id. Empty when unknown.
        public string voice_type;
        // Song section (e.g. "Chorus") from the TTML div songPart or a bare
        // [Chorus] marker line. Carried for format completeness; the
        // renderer intentionally ignores it.
        public string section;
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
