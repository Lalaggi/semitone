namespace G4 {

    // ── Format detection ──────────────────────────────────────────────

    public LyricsFormat detect_lyrics_format (string raw) {
        if (raw.contains ("<tt") || raw.contains ("<body")) {
            var doc = Xml.Parser.parse_memory (raw, raw.length);
            if (doc != null) {
                unowned Xml.Node* root = doc->get_root_element ();
                if (root != null) {
                    unowned Xml.Node* body = null;
                    for (var n = root->children; n != null; n = n->next) {
                        if (n->name == "body") { body = n; break; }
                    }
                    if (body != null) {
                        bool has_word_timing = false;
                        bool has_line_timing = false;
                        for (var div = body->children; div != null; div = div->next) {
                            if (div->type != Xml.ElementType.ELEMENT_NODE) continue;
                            for (var p = div->children; p != null; p = p->next) {
                                if (p->type != Xml.ElementType.ELEMENT_NODE) continue;
                                if (p->name != "p") continue;
                                if (p->get_prop ("begin") != null)
                                    has_line_timing = true;
                                for (var span = p->children; span != null; span = span->next) {
                                    if (span->type != Xml.ElementType.ELEMENT_NODE) continue;
                                    if (span->name != "span") continue;
                                    if (span->get_prop ("begin") != null && span->get_prop ("end") != null)
                                        has_word_timing = true;
                                }
                            }
                        }
                        delete doc;
                        if (has_word_timing) return LyricsFormat.TTML_WORD_SYNCED;
                        if (has_line_timing) return LyricsFormat.TTML_LINE_SYNCED;
                        return LyricsFormat.TTML_UNSYNCED;
                    }
                }
                delete doc;
            }
        }

        if (raw.contains ("<") && raw.contains (":")) {
            var lines = raw.split ("\n");
            bool has_v1_word_timing_line = false;
            bool has_v2_word_timing_line = false;
            bool has_inline_timing = false;
            foreach (var line in lines) {
                var ls = line.strip ();
                if (ls.has_prefix ("<")) {
                    if (looks_like_v2_timing_line (ls)) {
                        has_v2_word_timing_line = true;
                    } else if (ls.contains ("|") && ls.contains (":") && ls.contains (">")) {
                        // v1 bulk: <word:1.0:2.0|...> — not v2, has pipe and word text
                        has_v1_word_timing_line = true;
                    } else if (ls.contains (":") && ls.contains (">")) {
                        // fallback: any <...> with colon but not v2 could still be v1-like
                        // treat as v1 if inside not digit-start
                        var gt = ls.index_of_char ('>');
                        if (gt > 0) {
                            var inside = ls.substring (1, gt - 1).strip ();
                            if (inside.length > 0 && !inside[0].isdigit ())
                                has_v1_word_timing_line = true;
                        }
                    }
                    if (has_v1_word_timing_line || has_v2_word_timing_line) break;
                }
                if (ls.has_prefix ("[") && ls.contains ("]")) {
                    var bracket_close = ls.index_of_char (']');
                    var after_bracket = ls.substring (bracket_close + 1).strip ();
                    // Check for inline timestamps, possibly preceded by a voice
                    // prefix like "v1:" — e.g. [00:16.83]v1:<00:16.834>text
                    // Extended LRC has inline <mm:ss.xx> after the header timestamp;
                    // LRC+ v2 has separate line starting with "<", not inline.
                    if (after_bracket.has_prefix ("<")) {
                        if (after_bracket.contains (":") && after_bracket.contains (">")) {
                            // ensure it's not a v2 attr block like {voice:...} after ]
                            // inline timing must look like timestamp inside <>
                            var gt_inline = after_bracket.index_of_char ('>');
                            if (gt_inline > 0) {
                                var inside_inline = after_bracket.substring (1, gt_inline - 1).strip ();
                                if (parse_timestamp (inside_inline) >= 0)
                                    has_inline_timing = true;
                            }
                            if (has_inline_timing) break;
                        }
                    } else {
                        var lt_pos = after_bracket.index_of_char ('<');
                        if (lt_pos > 0 && lt_pos < 4) {
                            var inline = after_bracket.substring (lt_pos);
                            if (inline.contains (":") && inline.contains (">")) {
                                var gt_inline2 = inline.index_of_char ('>');
                                if (gt_inline2 > 0) {
                                    var inside_inline2 = inline.substring (1, gt_inline2 - 1).strip ();
                                    if (parse_timestamp (inside_inline2) >= 0)
                                        has_inline_timing = true;
                                }
                                if (has_inline_timing) break;
                            }
                        }
                    }
                }
            }
            if (has_v1_word_timing_line || has_v2_word_timing_line) return LyricsFormat.LRC_PLUS;
            if (has_inline_timing) return LyricsFormat.EXTENDED_LRC;
        }

        if (raw.contains ("[")) {
            var lines = raw.split ("\n");
            foreach (var line in lines) {
                var ls = line.strip ();
                if (ls.length >= 5 && ls[0] == '[') {
                    var close = ls.index_of_char (']');
                    if (close > 0) {
                        var ts = ls.substring (1, close - 1);
                        if (parse_timestamp (ts) >= 0)
                            return LyricsFormat.LRC;
                    }
                }
            }
        }

        return LyricsFormat.PLAIN;
    }

    public LyricLine[] parse (string raw, LyricsFormat format) {
        switch (format) {
            case LyricsFormat.TTML_WORD_SYNCED:
            case LyricsFormat.TTML_LINE_SYNCED:
            case LyricsFormat.TTML_UNSYNCED:
                return parse_ttml (raw);
            case LyricsFormat.LRC_PLUS:
                return parse_lrc_plus (raw);
            case LyricsFormat.EXTENDED_LRC:
                return parse_extended_lrc (raw);
            case LyricsFormat.LRC:
                return parse_lrc (raw);
            case LyricsFormat.PLAIN:
            default:
                return parse_plain (raw);
        }
    }

    // ── Candidate builder ─────────────────────────────────────────────

    public LyricsCandidate? lyrics_build_candidate (string raw, string provider, int index) {
        var format = detect_lyrics_format (raw);
        var parsed = parse (raw, format);
        if (parsed.length == 0) return null;
        bool synced = format != LyricsFormat.PLAIN && format != LyricsFormat.TTML_UNSYNCED;
        var score = lyrics_score_candidate (parsed, format, index, provider);
        LyricsCandidate c = { raw, provider, parsed, synced, score, format };
        return c;
    }

    // ── Plaintext conversion ──────────────────────────────────────────

    public string lyrics_convert_to_plaintext (string raw) {
        var format = detect_lyrics_format (raw);
        if (format == LyricsFormat.TTML_UNSYNCED) {
            return parse_ttml_unsynced_raw (raw);
        }
        return raw;
    }

    private string parse_ttml_unsynced_raw (string ttml) {
        var sb = new StringBuilder ();
        if (!ttml.contains ("<tt") && !ttml.contains ("<body"))
            return ttml;
        var doc = Xml.Parser.parse_memory (ttml, ttml.length);
        if (doc == null) return ttml;
        unowned Xml.Node* root = doc->get_root_element ();
        if (root == null) { delete doc; return ttml; }
        unowned Xml.Node* body = null;
        for (var n = root->children; n != null; n = n->next) {
            if (n->name == "body") { body = n; break; }
        }
        if (body == null) { delete doc; return ttml; }
        for (var div = body->children; div != null; div = div->next) {
            if (div->type != Xml.ElementType.ELEMENT_NODE) continue;
            for (var p = div->children; p != null; p = p->next) {
                if (p->type != Xml.ElementType.ELEMENT_NODE) continue;
                if (p->name != "p") continue;
                var text = p->get_content ();
                if (text.strip ().length > 0) {
                    sb.append (text.strip ());
                    sb.append_c ('\n');
                }
            }
        }
        delete doc;
        return sb.str.strip ();
    }

    // ── LRC metadata stripping ────────────────────────────────────────

    public string strip_lrc_metadata (string lrc) {
        var sb = new StringBuilder ();
        foreach (var line in lrc.split ("\n")) {
            var ls = line.strip ();
            if (ls.has_prefix ("[offset:") || ls.has_prefix ("[ti:") ||
                ls.has_prefix ("[ar:")     || ls.has_prefix ("[al:") ||
                ls.has_prefix ("[by:")     || ls.has_prefix ("[length:") ||
                ls.has_prefix ("[re:")     || ls.has_prefix ("[ve:"))
                continue;
            sb.append (ls);
            sb.append_c ('\n');
        }
        return sb.str;
    }

    // ── Parsers ───────────────────────────────────────────────────────

    // ── v2 helpers: KV attr-block parsing ───────────────────────────
    private string strip_quotes (string s) {
        var t = s.strip ();
        if (t.length >= 2 && ((t[0] == '"' && t[t.length-1] == '"') || (t[0] == '\'' && t[t.length-1] == '\'')))
            return t.substring (1, t.length - 2).strip ();
        return t;
    }

    private void parse_attr_block (string inner, out string voice, out string voice_display, out string style, out string effect, out string lang) {
        voice = ""; voice_display = ""; style = ""; effect = ""; lang = "";
        var trimmed = inner.strip ();
        if (trimmed.length == 0) return;
        // Legacy alias: no ':' and no '|' → treat as voice shorthand {v1}
        if (!trimmed.contains (":") && !trimmed.contains ("|")) {
            voice = strip_quotes (trimmed);
            return;
        }
        foreach (var attr in trimmed.split ("|")) {
            var kv = attr.split (":", 2);
            if (kv.length == 0) continue;
            var key = kv[0].strip ().down ();
            var val = kv.length > 1 ? kv[1].strip () : "";
            if (val.length == 0) continue;
            switch (key) {
                case "voice": {
                    // Support voice:id[,Display] or voice:id,"Display" -> split on comma
                    var parts = val.split (",", 2);
                    voice = strip_quotes (parts[0].strip ());
                    if (parts.length > 1) {
                        var disp = strip_quotes (parts[1].strip ());
                        if (disp.length > 0) voice_display = disp;
                    }
                    break;
                }
                case "display":
                case "name":
                case "label":
                case "agent-name": {
                    voice_display = strip_quotes (val);
                    break;
                }
                case "style": {
                    // filter to known tokens, drop unknown per spec
                    string[] allowed = { "bold", "italic", "underline", "strike" };
                    var filtered = new StringBuilder ();
                    bool first = true;
                    foreach (var tok in val.split (",")) {
                        var t = tok.strip ().down ();
                        if (t.length == 0) continue;
                        bool ok = false;
                        foreach (var a in allowed) if (t == a) { ok = true; break; }
                        if (!ok) continue;
                        if (!first) filtered.append_c (',');
                        filtered.append (t);
                        first = false;
                    }
                    if (filtered.len > 0) {
                        if (style.length > 0) style += "," + filtered.str;
                        else style = filtered.str;
                    }
                    break;
                }
                case "effect": effect = val; break;
                case "lang": lang = val; break;
                default: break; // unknown → skip per spec
            }
        }
    }

    private void parse_lrc_plus_header_attrs (string rest, out string voice, out string voice_display, out string style, out string effect, out string lang, out string text_without_block) {
        voice = ""; voice_display = ""; style = ""; effect = ""; lang = "";
        text_without_block = rest;
        if (rest.has_prefix ("{")) {
            var tag_end = rest.index_of_char ('}');
            if (tag_end >= 0) {
                var inner = rest.substring (1, tag_end - 1);
                parse_attr_block (inner, out voice, out voice_display, out style, out effect, out lang);
                text_without_block = rest.substring (tag_end + 1).strip ();
            }
        }
    }

    private bool looks_like_v2_timing_line (string line) {
        var ls = line.strip ();
        if (!ls.has_prefix ("<")) return false;
        var gt = ls.index_of_char ('>');
        if (gt < 0) return false;
        var inside = ls.substring (1, gt - 1).strip ();
        if (inside.length == 0) return false;
        // v1 bulk contains '|' or word text with letters before colon; v2 inside is pure timestamp(s)
        if (inside.contains ("|")) return false;
        // quick check: first char must be digit for v2 timestamp
        if (!inside[0].isdigit ()) return false;
        // try single timestamp e.g. "00:10.00"
        if (parse_timestamp (inside) >= 0) return true;
        // try double timestamp e.g. "00:10.00:00:10.32"
        // split by ":", expect 4 parts: mm, ss.xx, mm, ss.xx
        var parts = inside.split (":");
        if (parts.length == 4) {
            var start_ts = "%s:%s".printf (parts[0], parts[1]);
            var end_ts = "%s:%s".printf (parts[2], parts[3]);
            if (parse_timestamp (start_ts) >= 0 && parse_timestamp (end_ts) >= 0) return true;
        }
        return false;
    }

    public LyricWord[] parse_word_timings_v2 (string timing_line, int64 line_end_ms = -1) {
        LyricWord[] words = {};
        // track whether end was explicitly supplied per word
        bool[] has_explicit_end = {};
        var rest = timing_line.strip ();
        var pos = 0;
        while (pos < rest.length) {
            // skip WS
            while (pos < rest.length && rest[pos].isspace ()) pos++;
            if (pos >= rest.length) break;
            if (rest[pos] != '<') {
                // stray text without timing — could be word text containing '<' literal not encoded;
                // per spec literal '<' should be &lt;, so treat stray as error and skip to next '<'
                var next = rest.index_of_char ('<', pos);
                if (next < 0) break;
                // if no valid timestamp after, treat as text belonging to previous word — skip
                pos = next;
                continue;
            }
            var gt = rest.index_of_char ('>', pos);
            if (gt < 0) break;
            var inside = rest.substring (pos + 1, gt - pos - 1).strip ();
            int64 start_ms = -1;
            int64 end_ms = -1;
            bool explicit_end = false;
            // inside may be "00:10.00" or "00:10.00:00:10.32"
            if (inside.contains (":")) {
                var parts = inside.split (":");
                if (parts.length == 4) {
                    var start_ts = "%s:%s".printf (parts[0], parts[1]);
                    var end_ts = "%s:%s".printf (parts[2], parts[3]);
                    start_ms = parse_timestamp (start_ts);
                    end_ms = parse_timestamp (end_ts);
                    explicit_end = end_ms >= 0;
                } else if (parts.length == 2) {
                    start_ms = parse_timestamp (inside);
                } else {
                    start_ms = parse_timestamp (inside);
                }
            }
            pos = gt + 1;
            while (pos < rest.length && rest[pos].isspace ()) pos++;
            // Optional per-word attr block {style:bold|effect:shake}
            string w_style = ""; string w_effect = ""; string w_voice = ""; string w_voice_display = ""; string w_lang = "";
            if (pos < rest.length && rest[pos] == '{') {
                var w_end = rest.index_of_char ('}', pos);
                if (w_end >= 0) {
                    var w_inner = rest.substring (pos + 1, w_end - pos - 1);
                    parse_attr_block (w_inner, out w_voice, out w_voice_display, out w_style, out w_effect, out w_lang);
                    // w_voice/lang on word-level is ignored per spec (voice per line only), but parse and drop
                    pos = w_end + 1;
                    while (pos < rest.length && rest[pos].isspace ()) pos++;
                }
            }
            var word_start = pos;
            var next_lt = rest.index_of_char ('<', pos);
            string word_text;
            if (next_lt < 0) {
                word_text = rest.substring (word_start).strip ();
                pos = rest.length;
            } else {
                word_text = rest.substring (word_start, next_lt - word_start).strip ();
                pos = next_lt;
            }
            word_text = decode_html_entities (word_text);
            if (word_text.length == 0 || start_ms < 0) continue;
            double s = start_ms / 1000.0;
            // if no explicit end, use sentinel -1 to allow inference
            double e = explicit_end ? end_ms / 1000.0 : -1.0;
            LyricWord w = { word_text, s, e, w_style, w_effect };
            words += w;
            has_explicit_end += explicit_end;
        }
        // Fix end times: if missing or invalid, infer from next start; last word from line_end or +3s
        for (var i = 0; i < words.length; i++) {
            bool need_fix = !has_explicit_end[i] || words[i].end_sec <= words[i].start_sec;
            // also fix if explicit end overshoots next word
            if (i < words.length - 1 && has_explicit_end[i] && words[i].end_sec > words[i+1].start_sec)
                need_fix = true;
            if (need_fix) {
                if (i < words.length - 1) {
                    words[i].end_sec = words[i+1].start_sec;
                } else {
                    if (line_end_ms >= 0)
                        words[i].end_sec = line_end_ms / 1000.0;
                    else
                        words[i].end_sec = words[i].start_sec + 0.30;
                }
            }
        }
        return words;
    }

    public LyricLine[] parse_lrc_plus (string lrc) {
        if (!lrc.contains ("<")) return {};

        LyricLine[] result = {};
        var raw_lines = strip_lrc_metadata (lrc).split ("\n");
        var i = 0;
        while (i < raw_lines.length) {
            var line = raw_lines[i].strip ();
            i++;

            if (line.length < 5 || line[0] != '[') continue;

            var close = line.index_of_char (']');
            if (close < 0) continue;

            var timestamp = line.substring (1, close - 1);
            var rest = line.substring (close + 1).strip ();

            string voice_role, voice_display, style, effect, lang;
            string text_part;
            parse_lrc_plus_header_attrs (rest, out voice_role, out voice_display, out style, out effect, out lang, out text_part);

            var ms = parse_timestamp (timestamp);
            if (ms < 0) continue;

            var decoded_rest = decode_html_entities (text_part);

            LyricWord[] words = {};
            bool has_timing = false;
            if (i < raw_lines.length && raw_lines[i].strip ().has_prefix ("<")) {
                var timing_line = raw_lines[i].strip ();
                if (looks_like_v2_timing_line (timing_line)) {
                    // infer line_end for last word without explicit end: look ahead to next header timestamp
                    int64 line_end_ms = -1;
                    for (var j = i + 1; j < raw_lines.length; j++) {
                        var peek = raw_lines[j].strip ();
                        if (peek.length < 5 || peek[0] != '[') continue;
                        var pc = peek.index_of_char (']');
                        if (pc < 0) continue;
                        var pts = peek.substring (1, pc - 1);
                        var pms = parse_timestamp (pts);
                        if (pms >= 0) { line_end_ms = pms; break; }
                    }
                    if (line_end_ms < 0 && timing_line.length > 0) {
                        // fallback: last word start + 3s will be handled inside parse_word_timings_v2 via -1
                    }
                    words = parse_word_timings_v2 (timing_line, line_end_ms);
                } else {
                    words = parse_word_timings (timing_line);
                }
                has_timing = words.length > 0;
                // Also treat as timing line consumed even if empty parse (to skip it)
                if (timing_line.has_prefix ("<"))
                    i++;
            }
            // Strict isolation: no {…} without timing line
            if (!has_timing) {
                voice_role = "";
                voice_display = "";
                style = "";
                effect = "";
                lang = "";
                // If header had attr-block but no timing, the text_part already stripped the block;
                // For strict legacy safety we keep stripped text (attrs hidden) but clear attrs —
                // plain LRC readers would have seen attrs as text, so lint should warn producer.
            }

            LyricLine l = { ms, decoded_rest, words, voice_role, voice_display, style, effect, lang };
            result += l;
        }
        return deduplicate_lines (result);
    }

    private LyricLine[] deduplicate_lines (LyricLine[] input) {
        if (input.length <= 1) return input;
        LyricLine[] out = {};
        out += input[0];
        for (var i = 1; i < input.length; i++) {
            var prev = out[out.length - 1];
            var cur = input[i];
            bool same_time = (prev.time_ms == cur.time_ms) || (prev.time_ms >= 0 && cur.time_ms >= 0 && (prev.time_ms - cur.time_ms).abs () < 350);
            bool same_voice = prev.voice_role == cur.voice_role;
            bool same_text = prev.text.strip () == cur.text.strip ();
            bool words_similar = false;
            if (prev.words.length == cur.words.length && prev.words.length > 0) {
                bool all_words_match = true;
                for (var w = 0; w < prev.words.length; w++) {
                    if (prev.words[w].text.strip () != cur.words[w].text.strip ()) { all_words_match = false; break; }
                    if ((prev.words[w].start_sec - cur.words[w].start_sec).abs () > 0.15 ||
                        (prev.words[w].end_sec - cur.words[w].end_sec).abs () > 0.15) { all_words_match = false; break; }
                }
                words_similar = all_words_match;
            } else if (prev.words.length == 0 && cur.words.length == 0) {
                words_similar = true;
            }
            // Same timestamp + same voice + same text (+ similar words) => buggy upstream duplicate -> drop cur
            if (same_time && same_voice && same_text && (words_similar || (prev.words.length > 0 && cur.words.length > 0))) {
                continue;
            }
            // Also catch exact duplicate regardless of small timing slop when text/voice identical and no voice tag (default v1)
            if (same_time && same_voice && same_text && same_voice && prev.voice_role == "" && cur.voice_role == "") {
                // already handled above, but keep stricter: if time identical and text identical, dedup
                continue;
            }
            out += cur;
        }
        return out;
    }

    public LyricLine[] parse_extended_lrc (string lrc) {
        if (!lrc.contains ("<")) return {};

        var stripped = strip_lrc_metadata (lrc);
        var raw_lines_arr = stripped.split ("\n");

        int64[] line_timestamps = {};
        string[] line_texts = {};
        foreach (var raw_line in raw_lines_arr) {
            var line = raw_line.strip ();
            if (line.length < 5 || line[0] != '[') continue;
            var close = line.index_of_char (']');
            if (close < 0) continue;
            var line_ms = parse_timestamp (line.substring (1, close - 1));
            if (line_ms < 0) continue;
            line_timestamps += line_ms;
            line_texts += line;
        }

        LyricLine[] result = {};
        for (var li = 0; li < line_texts.length; li++) {
            var line = line_texts[li];
            var close = line.index_of_char (']');
            var line_ms = line_timestamps[li];

            var rest = line.substring (close + 1);
            var first_tag = rest.index_of_char ('<');

            // Extract voice role from prefix like "v1:" before the first inline tag
            var voice_role = "";
            if (first_tag > 0) {
                var prefix = rest.substring (0, first_tag).strip ();
                if (prefix.has_suffix (":")) {
                    voice_role = prefix.substring (0, prefix.length - 1);
                    rest = rest.substring (first_tag);
                } else {
                    rest = rest.substring (first_tag);
                }
            }

            LyricWord[] words = {};
            var text_sb = new StringBuilder ();
            var pos = 0;

            while (pos < rest.length) {
                if (rest[pos] == '<') {
                    var end = rest.index_of_char ('>', pos);
                    if (end < 0) break;
                    var ts_str = rest.substring (pos + 1, end - pos - 1);
                    var word_start_ms = parse_timestamp (ts_str);
                    pos = end + 1;

                    var word_start = pos;
                    while (pos < rest.length && rest[pos] != '<')
                        pos++;
                    var word_text = rest.substring (word_start, pos - word_start);
                    word_text = decode_html_entities (word_text).strip ();

                    if (word_text.length > 0 && word_start_ms >= 0) {
                        LyricWord w = { word_text, word_start_ms / 1000.0, 0.0, "", "" };
                        words += w;
                        text_sb.append (word_text);
                        text_sb.append_c (' ');
                    }
                } else {
                    pos++;
                }
            }

            double line_end_sec = (li + 1 < line_timestamps.length)
                ? line_timestamps[li + 1] / 1000.0
                : (words.length > 0 ? words[words.length - 1].start_sec + 3.0 : 0.0);

            for (var i = 0; i < words.length - 1; i++)
                words[i].end_sec = words[i + 1].start_sec;
            if (words.length > 0)
                words[words.length - 1].end_sec = line_end_sec;

            LyricLine l = { line_ms, text_sb.str.strip (), words, voice_role, "", "", "", "" };
            result += l;
        }
        return deduplicate_lines (result);
    }

    public LyricLine[] parse_lrc (string lrc) {
        LyricLine[] result = {};
        var raw_lines = strip_lrc_metadata (lrc).split ("\n");
        var i = 0;
        while (i < raw_lines.length) {
            var line = raw_lines[i].strip ();
            i++;

            if (line.length < 5 || line[0] != '[') continue;

            var close = line.index_of_char (']');
            if (close < 0) continue;

            var timestamp = line.substring (1, close - 1);
            var rest = line.substring (close + 1).strip ();

            var voice_role = "";
            if (rest.has_prefix ("{")) {
                var tag_end = rest.index_of_char ('}');
                if (tag_end >= 0) {
                    voice_role = rest.substring (1, tag_end - 1);
                    rest = rest.substring (tag_end + 1).strip ();
                }
            }

            var ms = parse_timestamp (timestamp);
            if (ms < 0) continue;

            LyricWord[] words = {};
            if (i < raw_lines.length && raw_lines[i].strip ().has_prefix ("<")) {
                words = parse_word_timings (raw_lines[i].strip ());
                // strict isolation: if no words parsed, drop legacy voice on plain LRC line
                if (words.length == 0)
                    voice_role = "";
                else
                    i++;
            } else {
                voice_role = "";
            }

            var decoded_rest = decode_html_entities (rest);
            LyricLine l = { ms, decoded_rest, words, voice_role, "", "", "", "" };
            result += l;
        }
        return deduplicate_lines (result);
    }

    public LyricLine[] parse_plain (string text) {
        LyricLine[] result = {};
        foreach (var line in text.split ("\n")) {
            var trimmed = line.strip ();
            if (trimmed.length > 0 && trimmed[0] == '[' && parse_timestamp (
                    trimmed.substring (1, trimmed.index_of_char (']') > 0
                        ? trimmed.index_of_char (']') - 1 : 0)) >= 0)
                continue;
            LyricWord[] empty_words = {};
            LyricLine l = { -1, trimmed, empty_words, "", "", "", "", "" };
            result += l;
        }
        var start = 0;
        var end = result.length - 1;
        while (start <= end && result[start].text.length == 0) start++;
        while (end >= start && result[end].text.length == 0) end--;
        return result[start:end + 1];
    }

    // ── TTML agent pretty-name extraction ───────────────────────────────
    private HashTable<string,string> extract_ttml_agents (Xml.Node* root) {
        var agents = new HashTable<string,string> (str_hash, str_equal);
        // find head
        unowned Xml.Node* head = null;
        for (var c = root->children; c != null; c = c->next) {
            if (c->name == "head" || c->name.has_suffix ("head")) { head = c; break; }
        }
        if (head == null) return agents;
        // walk recursively to find <agent> or <ttm:agent>
        GLib.Queue<unowned Xml.Node*> q = new GLib.Queue<unowned Xml.Node*> ();
        q.push_head (head);
        while (!q.is_empty ()) {
            unowned Xml.Node* cur = q.pop_head ();
            for (var n = cur->children; n != null; n = n->next) {
                if (n->type != Xml.ElementType.ELEMENT_NODE) continue;
                var nname = n->name;
                if (nname == "agent" || nname.has_suffix (":agent")) {
                    // xml:id may be "id" or "xml:id"
                    string? id = n->get_prop ("xml:id");
                    if (id == null) id = n->get_prop ("id");
                    if (id != null && ((!)id).length > 0) {
                        string display = "";
                        // look for child <name> or <ttm:name> or attribute displayName/name
                        string? aname = n->get_prop ("displayName");
                        if (aname == null) aname = n->get_prop ("name");
                        if (aname != null && ((!)aname).strip ().length > 0) display = ((!)aname).strip ();
                        // search child nodes for <name> or ttm:name
                        for (var ch = n->children; ch != null; ch = ch->next) {
                            if (ch->type != Xml.ElementType.ELEMENT_NODE) continue;
                            var chname = ch->name;
                            if (chname == "name" || chname.has_suffix (":name")) {
                                var txt = ch->get_content ();
                                if (txt.strip ().length > 0) { display = txt.strip (); break; }
                            }
                            // also check nested metadata
                            for (var gch = ch->children; gch != null; gch = gch->next) {
                                if (gch->type != Xml.ElementType.ELEMENT_NODE) continue;
                                var gname = gch->name;
                                if (gname == "name" || gname.has_suffix (":name")) {
                                    var gtxt = gch->get_content ();
                                    if (gtxt.strip ().length > 0) { display = gtxt.strip (); break; }
                                }
                            }
                            if (display.length > 0) break;
                        }
                        if (display.length > 0) agents.set ((!)id, display);
                    }
                }
                q.push_tail (n);
            }
        }
        return agents;
    }

    private string agent_display_for (HashTable<string,string> agents, string voice_role) {
        if (voice_role.length == 0) return "";
        if (voice_role == "bg") return "";
        string? v = agents.lookup (voice_role);
        if (v != null) return (!)v;
        // also try lower case?
        v = agents.lookup (voice_role.down ());
        if (v != null) return (!)v;
        return "";
    }

    // ── TTML parsers ──────────────────────────────────────────────────

    public LyricLine[] parse_ttml (string ttml) {
        LyricLine[] result = {};
        if (!ttml.contains ("<tt") && !ttml.contains ("<body"))
            return result;
        var doc = Xml.Parser.parse_memory (ttml, ttml.length);
        if (doc == null) return result;
        unowned Xml.Node* root = doc->get_root_element ();
        if (root == null) { delete doc; return result; }

        unowned Xml.Node* body = null;
        for (var n = root->children; n != null; n = n->next) {
            if (n->name == "body") { body = n; break; }
        }
        if (body == null) { delete doc; return result; }

        bool has_line_timing = false;
        bool has_word_timing = false;

        for (var div = body->children; div != null; div = div->next) {
            if (div->type != Xml.ElementType.ELEMENT_NODE) continue;
            for (var p = div->children; p != null; p = p->next) {
                if (p->type != Xml.ElementType.ELEMENT_NODE) continue;
                if (p->name != "p") continue;
                if (p->get_prop ("begin") != null) {
                    has_line_timing = true;
                }
                for (var span = p->children; span != null; span = span->next) {
                    if (span->type != Xml.ElementType.ELEMENT_NODE) continue;
                    if (span->name != "span") continue;
                    if (span->get_prop ("begin") != null && span->get_prop ("end") != null) {
                        has_word_timing = true;
                    }
                }
            }
        }

        var agents = extract_ttml_agents (root);
        LyricLine[] ttml_result;
        if (has_word_timing) {
            ttml_result = parse_ttml_word_synced (body, agents);
        } else if (has_line_timing) {
            ttml_result = parse_ttml_line_synced (body, agents);
        } else {
            ttml_result = parse_ttml_unsynced (body);
        }
        delete doc;
        return ttml_result;
    }

    private LyricLine[] parse_ttml_unsynced (Xml.Node* body) {
        LyricLine[] result = {};
        for (var div = body->children; div != null; div = div->next) {
            if (div->type != Xml.ElementType.ELEMENT_NODE) continue;
            for (var p = div->children; p != null; p = p->next) {
                if (p->type != Xml.ElementType.ELEMENT_NODE) continue;
                if (p->name != "p") continue;
                var text = p->get_content ();
                if (text.strip ().length > 0) {
                    LyricWord[] empty_words = {};
                    LyricLine l = { -1, text.strip (), empty_words, "", "", "", "" };
                    result += l;
                }
            }
        }
        return result;
    }

    private LyricLine[] parse_ttml_line_synced (Xml.Node* body, HashTable<string,string>? agents = null) {
        LyricLine[] result = {};
        for (var div = body->children; div != null; div = div->next) {
            if (div->type != Xml.ElementType.ELEMENT_NODE) continue;
            for (var p = div->children; p != null; p = p->next) {
                if (p->type != Xml.ElementType.ELEMENT_NODE) continue;
                if (p->name != "p") continue;

                var begin_str = p->get_prop ("begin");
                if (begin_str == null) continue;
                var ms = ttml_time_to_ms ((!)begin_str);
                if (ms < 0) continue;

                var p_agent = p->get_prop ("agent");
                string voice_role = "";
                if (p_agent != null && (!)p_agent != "v1")
                    voice_role = (!)p_agent;
                string voice_display = "";
                if (agents != null) {
                    // try raw agent id first (preserves v1 pretty name), fallback to role
                    string raw = p_agent ?? "";
                    voice_display = agent_display_for ((!)agents, raw);
                    if (voice_display.length == 0) voice_display = agent_display_for ((!)agents, voice_role);
                }

                var p_content = p->get_content ();

                LyricWord[] main_words = {};
                LyricWord[] bg_words = {};
                var line_text_sb = new StringBuilder ();

                for (var span = p->children; span != null; span = span->next) {
                    if (span->type != Xml.ElementType.ELEMENT_NODE) continue;
                    if (span->name != "span") continue;

                    var role = span->get_prop ("role");
                    bool is_this_bg = (role != null && (!)role == "x-bg");
                    var w_text = span->get_content ();

                    if (is_this_bg) {
                        for (var ws = span->children; ws != null; ws = ws->next) {
                            if (ws->type != Xml.ElementType.ELEMENT_NODE) continue;
                            var w_begin = ws->get_prop ("begin");
                            var w_end = ws->get_prop ("end");
                            var w_content = ws->get_content ();
                            if (w_begin != null && w_end != null && w_content.length > 0) {
                                LyricWord w = {
                                    w_content,
                                    ttml_time_to_ms ((!)w_begin) / 1000.0,
                                    ttml_time_to_ms ((!)w_end) / 1000.0,
                                    "", ""
                                };
                                bg_words += w;
                            }
                        }
                    } else {
                        var w_begin = span->get_prop ("begin");
                        var w_end = span->get_prop ("end");
                        if (w_begin != null && w_end != null && w_text.length > 0) {
                            LyricWord w = {
                                w_text,
                                ttml_time_to_ms ((!)w_begin) / 1000.0,
                                ttml_time_to_ms ((!)w_end) / 1000.0,
                                "", ""
                            };
                            main_words += w;
                            line_text_sb.append (w_text);
                            line_text_sb.append_c (' ');
                        }
                    }
                }

                if (line_text_sb.len == 0 && p_content.length > 0) {
                    line_text_sb.append (p_content);
                }

                var line_text = line_text_sb.str.strip ();
                if (line_text.length == 0) continue;

                LyricLine main_line = { ms, line_text, main_words, voice_role, voice_display, "", "", "" };
                result += main_line;

                if (bg_words.length > 0) {
                    var bg_text_sb = new StringBuilder ();
                    foreach (var bw in bg_words) {
                        bg_text_sb.append (bw.text);
                        bg_text_sb.append_c (' ');
                    }
                    LyricLine bg_line = { ms, bg_text_sb.str.strip (), bg_words, "bg", "", "", "", "" };
                    result += bg_line;
                }
            }
        }
        return result;
    }

    private LyricLine[] parse_ttml_word_synced (Xml.Node* body, HashTable<string,string>? agents = null) {
        LyricLine[] result = {};
        for (var div = body->children; div != null; div = div->next) {
            if (div->type != Xml.ElementType.ELEMENT_NODE) continue;
            for (var p = div->children; p != null; p = p->next) {
                if (p->type != Xml.ElementType.ELEMENT_NODE) continue;
                if (p->name != "p") continue;

                var begin_str = p->get_prop ("begin");
                if (begin_str == null) continue;
                var line_ms = ttml_time_to_ms ((!)begin_str);
                if (line_ms < 0) continue;

                var p_agent = p->get_prop ("agent");
                string voice_role = "";
                if (p_agent != null && (!)p_agent != "v1")
                    voice_role = (!)p_agent;
                // keep raw agent for display lookup (preserves v1 pretty name)
                string raw_agent = p_agent ?? "";
                string last_agent = raw_agent;
                // voice_display will be resolved after span loop (span agent may override)
                string voice_display = "";

                LyricWord[] main_words = {};
                LyricWord[] bg_words = {};
                var main_text_sb = new StringBuilder ();
                var bg_text_sb = new StringBuilder ();

                for (var span = p->children; span != null; span = span->next) {
                    if (span->type != Xml.ElementType.ELEMENT_NODE) continue;
                    if (span->name != "span") continue;

                    var role = span->get_prop ("role");
                    bool is_bg = (role != null && (!)role == "x-bg");
                    var span_agent = span->get_prop ("agent");
                    if (!is_bg && span_agent != null && (!)span_agent != "v1") {
                        voice_role = (!)span_agent;
                        last_agent = (!)span_agent;
                    } else if (!is_bg && span_agent != null) {
                        // v1 case: voice_role stays "" but keep last_agent for display
                        last_agent = (!)span_agent;
                    }

                    if (is_bg) {
                        for (var ws = span->children; ws != null; ws = ws->next) {
                            if (ws->type != Xml.ElementType.ELEMENT_NODE) continue;
                            var w_begin = ws->get_prop ("begin");
                            var w_end = ws->get_prop ("end");
                            var w_content = ws->get_content ();
                            if (w_begin != null && w_end != null && w_content.length > 0) {
                                LyricWord w = { w_content, ttml_time_to_ms ((!)w_begin) / 1000.0, ttml_time_to_ms ((!)w_end) / 1000.0, "", "" };
                                bg_words += w;
                                bg_text_sb.append (w_content);
                                bg_text_sb.append_c (' ');
                            }
                        }
                    } else {
                        var w_begin_str = span->get_prop ("begin");
                        var w_end_str = span->get_prop ("end");
                        var w_text = span->get_content ();
                        if (w_begin_str != null && w_end_str != null && w_text.length > 0) {
                            var w_begin = ttml_time_to_ms ((!)w_begin_str);
                            var w_end = ttml_time_to_ms ((!)w_end_str);
                            if (w_begin >= 0 && w_end >= 0) {
                                LyricWord w = { w_text, w_begin / 1000.0, w_end / 1000.0, "", "" };
                                main_words += w;
                                main_text_sb.append (w_text);
                                main_text_sb.append_c (' ');
                            }
                        }
                    }
                }

                // resolve display name after final voice_role (p_agent + span_agent)
                if (agents != null) {
                    voice_display = agent_display_for ((!)agents, voice_role);
                    if (voice_display.length == 0 && last_agent.length > 0)
                        voice_display = agent_display_for ((!)agents, last_agent);
                }
                if (main_words.length > 0 || main_text_sb.str.strip ().length > 0) {
                    LyricLine l = { line_ms, main_text_sb.str.strip (), main_words, voice_role, voice_display, "", "", "" };
                    result += l;
                }

                if (bg_words.length > 0) {
                    LyricLine bg_line = { line_ms, bg_text_sb.str.strip (), bg_words, "bg", "", "", "", "" };
                    result += bg_line;
                }
            }
        }
        return result;
    }

    // ── Helpers ───────────────────────────────────────────────────────

    public LyricWord[] parse_word_timings (string timing_line) {
        LyricWord[] words = {};
        var inner = timing_line;
        if (inner.has_prefix ("<")) inner = inner.substring (1);
        if (inner.has_suffix (">")) inner = inner.substring (0, inner.length - 1);

        var parts = inner.split ("|");
        foreach (var part in parts) {
            var segments = part.split (":");
            if (segments.length >= 3) {
                var text = decode_html_entities (segments[0]);
                LyricWord w = { text, double.parse (segments[1]), double.parse (segments[2]), "", "" };
                words += w;
            }
        }
        return words;
    }

    public string decode_html_entities (string s) {
        return s.replace ("&#x27;", "'")
                .replace ("&apos;", "'")
                .replace ("&quot;", "\"")
                .replace ("&amp;", "&")
                .replace ("&lt;", "<")
                .replace ("&gt;", ">");
    }

    public int64 parse_timestamp (string ts) {
        var parts = ts.split (":");
        if (parts.length != 2) return -1;
        var minutes = int.parse (parts[0]);
        var sec_parts = parts[1].split (".");
        if (sec_parts.length != 2) return -1;
        var seconds = int.parse (sec_parts[0]);
        var frac = sec_parts[1];
        var frac_val = int.parse (frac);
        if (frac.length == 3)
            return (int64) (minutes * 60 * 1000 + seconds * 1000 + frac_val);
        if (frac.length == 2)
            return (int64) (minutes * 60 * 1000 + seconds * 1000 + frac_val * 10);
        if (frac.length == 1)
            return (int64) (minutes * 60 * 1000 + seconds * 1000 + frac_val * 100);
        return -1;
    }

    public int64 ttml_time_to_ms (string t) {
        var parts = t.split (":");
        if (parts.length == 3) {
            var h = int.parse (parts[0]);
            var m = int.parse (parts[1]);
            var s = double.parse (parts[2]);
            return (int64) ((h * 3600 + m * 60 + s) * 1000);
        } else if (parts.length == 2) {
            var m = int.parse (parts[0]);
            var s = double.parse (parts[1]);
            return (int64) ((m * 60 + s) * 1000);
        } else {
            return (int64) (double.parse (t) * 1000);
        }
    }

    // ── Serializer ────────────────────────────────────────────────────

    public string format_ms_as_timestamp (int64 ms) {
        int64 mins = ms / 1000 / 60;
        int64 secs = (ms / 1000) % 60;
        int64 cs = (ms % 1000) / 10;
        // truncates to centiseconds (10ms granularity) to match v1 spec LRCPLUS_SPEC.md:108
        // preserves backward compat; parsing accepts 1-3 frac digits so cs file round-trips
        return "%02lld:%02lld.%02lld".printf (mins, secs, cs);
    }

    public string format_sec_as_timestamp (double sec) {
        int64 ms = (int64) (sec * 1000);
        return format_ms_as_timestamp (ms);
    }

    private string build_header_attr_block (LyricLine l) {
        // Strict isolation already enforced on parse; serialize only if words exist
        if (l.words.length == 0) return "";
        var parts = new StringBuilder ();
        if (l.voice_role.length > 0) {
            parts.append ("voice:%s".printf (l.voice_role));
        }
        if (l.voice_display.length > 0) {
            if (parts.len > 0) parts.append_c ('|');
            // escape quotes if display contains '"' or '|' or '}'
            var disp = l.voice_display;
            // if display contains '|' '}' ',' or space, quote it
            bool needs_quotes = disp.contains ("|") || disp.contains ("}") || disp.contains (",") || disp.contains ("\"") || disp.contains (" ");
            if (needs_quotes) {
                // escape internal quotes
                disp = disp.replace ("\"", "&quot;");
                parts.append ("display:\"%s\"".printf (disp));
            } else {
                parts.append ("display:%s".printf (disp));
            }
        }
        if (l.style.length > 0) {
            if (parts.len > 0) parts.append_c ('|');
            parts.append ("style:%s".printf (l.style));
        }
        if (l.effect.length > 0) {
            if (parts.len > 0) parts.append_c ('|');
            parts.append ("effect:%s".printf (l.effect));
        }
        if (l.lang.length > 0) {
            if (parts.len > 0) parts.append_c ('|');
            parts.append ("lang:%s".printf (l.lang));
        }
        if (parts.len == 0) return "";
        return "{%s}".printf (parts.str);
    }

    public string serialize_to_lrc_plus (LyricLine[] lines) {
        var sb = new StringBuilder ();
        foreach (var l in lines) {
            if (l.time_ms < 0) continue;
            sb.append ("[%s]".printf (format_ms_as_timestamp (l.time_ms)));
            var block = build_header_attr_block (l);
            if (block.length > 0)
                sb.append (block);
            sb.append (l.text);
            sb.append_c ('\n');

            if (l.words.length > 0) {
                // v2 inline Variant A absolute: <mm:ss.xx:mm:ss.xx>{style:}Word ...
                for (var wi = 0; wi < l.words.length; wi++) {
                    var w = l.words[wi];
                    var start_ts = format_sec_as_timestamp (w.start_sec);
                    var end_ts = format_sec_as_timestamp (w.end_sec);
                    sb.append ("<%s:%s>".printf (start_ts, end_ts));
                    string w_block = "";
                    if (w.style.length > 0 || w.effect.length > 0) {
                        var wb = new StringBuilder ();
                        bool wfirst = true;
                        if (w.style.length > 0) { wb.append ("style:%s".printf (w.style)); wfirst = false; }
                        if (w.effect.length > 0) {
                            if (!wfirst) wb.append_c ('|');
                            wb.append ("effect:%s".printf (w.effect));
                        }
                        w_block = "{%s}".printf (wb.str);
                    }
                    if (w_block.length > 0) sb.append (w_block);
                    sb.append (w.text);
                    if (wi < l.words.length - 1) sb.append_c (' ');
                }
                sb.append_c ('\n');
            }
        }
        return sb.str;
    }

    // Keep v1 bulk serializer for compat/tests if needed
    public string serialize_to_lrc_plus_v1 (LyricLine[] lines) {
        var sb = new StringBuilder ();
        foreach (var l in lines) {
            if (l.time_ms < 0) continue;
            int64 mins = l.time_ms / 1000 / 60;
            int64 secs = (l.time_ms / 1000) % 60;
            int64 cs = (l.time_ms % 1000) / 10;
            sb.append ("[%02lld:%02lld.%02lld]".printf (mins, secs, cs));
            if (l.voice_role.length > 0)
                sb.append ("{%s}".printf (l.voice_role));
            sb.append (l.text);
            sb.append_c ('\n');
            if (l.words.length > 0) {
                sb.append_c ('<');
                for (var wi = 0; wi < l.words.length; wi++) {
                    if (wi > 0) sb.append_c ('|');
                    sb.append ("%s:%.3f:%.3f".printf (
                        l.words[wi].text,
                        l.words[wi].start_sec,
                        l.words[wi].end_sec));
                }
                sb.append (">\n");
            }
        }
        return sb.str;
    }
}
