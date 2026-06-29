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
            bool has_word_timing_line = false;
            bool has_inline_timing = false;
            foreach (var line in lines) {
                var ls = line.strip ();
                if (ls.has_prefix ("<") && ls.contains (":") && ls.contains ("|")) {
                    has_word_timing_line = true;
                    break;
                }
                if (ls.has_prefix ("[") && ls.contains ("]")) {
                    var bracket_close = ls.index_of_char (']');
                    var after_bracket = ls.substring (bracket_close + 1).strip ();
                    if (after_bracket.has_prefix ("<") && after_bracket.contains (":") && after_bracket.contains (">")) {
                        has_inline_timing = true;
                        break;
                    }
                }
            }
            if (has_word_timing_line) return LyricsFormat.LRC_PLUS;
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
        var score = lyrics_score_candidate (parsed, synced, raw, index, provider);
        LyricsCandidate c = { raw, provider, parsed, synced, score };
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

            var decoded_rest = decode_html_entities (rest);

            LyricWord[] words = {};
            if (i < raw_lines.length && raw_lines[i].strip ().has_prefix ("<")) {
                words = parse_word_timings (raw_lines[i].strip ());
                i++;
            }

            LyricLine l = { ms, decoded_rest, words, voice_role };
            result += l;
        }
        return result;
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
            if (first_tag > 0)
                rest = rest.substring (first_tag);

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
                        LyricWord w = { word_text, word_start_ms / 1000.0, 0.0 };
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

            LyricLine l = { line_ms, text_sb.str.strip (), words, "" };
            result += l;
        }
        return result;
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
                i++;
            }

            var decoded_rest = decode_html_entities (rest);
            LyricLine l = { ms, decoded_rest, words, voice_role };
            result += l;
        }
        return result;
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
            LyricLine l = { -1, trimmed, empty_words, "" };
            result += l;
        }
        var start = 0;
        var end = result.length - 1;
        while (start <= end && result[start].text.length == 0) start++;
        while (end >= start && result[end].text.length == 0) end--;
        return result[start:end + 1];
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

        if (has_word_timing) {
            return parse_ttml_word_synced (body);
        } else if (has_line_timing) {
            return parse_ttml_line_synced (body);
        } else {
            return parse_ttml_unsynced (body);
        }
    }

    private LyricLine[] parse_ttml_unsynced (unowned Xml.Node* body) {
        LyricLine[] result = {};
        for (var div = body->children; div != null; div = div->next) {
            if (div->type != Xml.ElementType.ELEMENT_NODE) continue;
            for (var p = div->children; p != null; p = p->next) {
                if (p->type != Xml.ElementType.ELEMENT_NODE) continue;
                if (p->name != "p") continue;
                var text = p->get_content ();
                if (text.strip ().length > 0) {
                    LyricWord[] empty_words = {};
                    LyricLine l = { -1, text.strip (), empty_words, "" };
                    result += l;
                }
            }
        }
        return result;
    }

    private LyricLine[] parse_ttml_line_synced (unowned Xml.Node* body) {
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
                                    ttml_time_to_ms ((!)w_end) / 1000.0
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
                                ttml_time_to_ms ((!)w_end) / 1000.0
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

                LyricLine main_line = { ms, line_text, main_words, voice_role };
                result += main_line;

                if (bg_words.length > 0) {
                    var bg_text_sb = new StringBuilder ();
                    foreach (var bw in bg_words) {
                        bg_text_sb.append (bw.text);
                        bg_text_sb.append_c (' ');
                    }
                    LyricLine bg_line = { ms, bg_text_sb.str.strip (), bg_words, "bg" };
                    result += bg_line;
                }
            }
        }
        return result;
    }

    private LyricLine[] parse_ttml_word_synced (unowned Xml.Node* body) {
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
                    if (!is_bg && span_agent != null && (!)span_agent != "v1")
                        voice_role = (!)span_agent;

                    if (is_bg) {
                        for (var ws = span->children; ws != null; ws = ws->next) {
                            if (ws->type != Xml.ElementType.ELEMENT_NODE) continue;
                            var w_begin = ws->get_prop ("begin");
                            var w_end = ws->get_prop ("end");
                            var w_content = ws->get_content ();
                            if (w_begin != null && w_end != null && w_content.length > 0) {
                                LyricWord w = { w_content, ttml_time_to_ms ((!)w_begin) / 1000.0, ttml_time_to_ms ((!)w_end) / 1000.0 };
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
                                LyricWord w = { w_text, w_begin / 1000.0, w_end / 1000.0 };
                                main_words += w;
                                main_text_sb.append (w_text);
                                main_text_sb.append_c (' ');
                            }
                        }
                    }
                }

                if (main_words.length > 0 || main_text_sb.str.strip ().length > 0) {
                    LyricLine l = { line_ms, main_text_sb.str.strip (), main_words, voice_role };
                    result += l;
                }

                if (bg_words.length > 0) {
                    LyricLine bg_line = { line_ms, bg_text_sb.str.strip (), bg_words, "bg" };
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
                LyricWord w = { text, double.parse (segments[1]), double.parse (segments[2]) };
                words += w;
            }
        }
        return words;
    }

    public string decode_html_entities (string s) {
        return s.replace ("&#x27;", "'")
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
        return (int64) (minutes * 60 * 1000 + seconds * 1000 + frac_val * 10);
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

    public string serialize_to_lrc_plus (LyricLine[] lines) {
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
