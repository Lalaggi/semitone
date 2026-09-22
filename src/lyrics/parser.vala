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
                // Timing lines may carry a leading {…} voice/style block;
                // run all checks on the units part after it.
                var units = timing_units_part (ls);
                if (units != null) {
                    var uparts = (!)units;
                    if (looks_like_v2_timing_line (uparts)) {
                        has_v2_word_timing_line = true;
                    } else if (uparts.contains ("|") && uparts.contains (":") && uparts.contains (">")) {
                        // v1 bulk: <word:1.0:2.0|...> — not v2, has pipe and word text
                        has_v1_word_timing_line = true;
                    } else if (uparts.contains (":") && uparts.contains (">")) {
                        // fallback: any <...> with colon but not v2 could still be v1-like
                        // treat as v1 if inside not digit-start
                        var gt = uparts.index_of_char ('>');
                        if (gt > 0) {
                            var inside = uparts.substring (1, gt - 1).strip ();
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
                    // LRC+ v2 has a separate timing line ('<…>' units,
                    // optionally '{…}<…>' with a leading voice/style block).
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
                        // Inline word timings, optionally prefixed with a
                        // voice tag like "v1:" (Paxsenix elrcMultiPerson).
                        var lt_pos = after_bracket.index_of_char ('<');
                        if (lt_pos >= 0) {
                            var prefix = after_bracket.substring (0, lt_pos).strip ();
                            bool prefix_ok = prefix.length == 0 || is_voice_prefix (prefix);
                            if (prefix_ok) {
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
            // Voice-table definitions ([@...] legacy, @[...] canonical) are
            // file-level metadata: must-ignore for legacy players and
            // consumed separately via parse_voice_defs() before stripping.
            // Canonical form puts '@' first (@[v1:...]) so even dumb
            // '['-scanning players skip the line instantly.
            if (ls.has_prefix ("[@") || ls.has_prefix ("@["))
                continue;
            sb.append (ls);
            sb.append_c ('\n');
        }
        return sb.str;
    }

    // ── Voice table (@[id,"name","credit",type=x]) ───────────────────
    //
    // File-level voice definitions, e.g.:
    //   @[v1,"Glinda","Kristin Chenoweth",type=person]
    //   @[v2,"Elphaba","Idina Menzel",type=person]
    //   @[v1000,type=group]
    // Grammar: "@" "[" voice-id [":" display ["|" credit]] "]"
    // voice-id = 1*(ALNUM / "-" / "_"); display/credit tokens may be
    // single- or double-quoted (required if they contain '|' or ']').
    // '@' comes first so legacy '['-anchored players skip the line without
    // even trying to parse a timestamp. The legacy [@...] spelling is
    // accepted on read. These lines are must-ignore for legacy players and
    // are stripped by strip_lrc_metadata(); per-line display names are
    // resolved from this table so timing lines only carry the short {v1}
    // tag and headers stay completely bare (no {…} at all).

    private bool is_voice_id_char (char c) {
        return c.isalnum () || c == '-' || c == '_';
    }

    private bool is_voice_prefix (string prefix) {
        // e.g. "v1:" — voice id + colon (Paxsenix elrcMultiPerson inline tag)
        if (!prefix.has_suffix (":")) return false;
        var id = prefix.substring (0, prefix.length - 1).strip ();
        if (id.length == 0) return false;
        for (var k = 0; k < id.length; k++) {
            if (!is_voice_id_char (id[k])) return false;
        }
        return true;
    }

    private void parse_voice_defs (string raw,
                                   out HashTable<string,string> displays,
                                   out HashTable<string,string> credits,
                                   out HashTable<string,string> types) {
        displays = new HashTable<string,string> (str_hash, str_equal);
        credits = new HashTable<string,string> (str_hash, str_equal);
        types = new HashTable<string,string> (str_hash, str_equal);
        foreach (var line in raw.split ("\n")) {
            var ls = line.strip ();
            // Canonical @[...] first; legacy [@...] accepted on read.
            string? inner = null;
            if (ls.has_prefix ("@[") && ls.has_suffix ("]")) {
                inner = ls.substring (2, ls.length - 3).strip ();
            } else if (ls.has_prefix ("[@") && ls.has_suffix ("]")) {
                inner = ls.substring (2, ls.length - 3).strip ();
            }
            if (inner == null) continue;
            var body = (!)inner;
            if (body.length == 0) continue;
            string id;
            string rest = "";
            // Id runs up to the first ':' (legacy @[v1:...]) or ','
            // (canonical @[v1,...]).
            var colon = body.index_of_char (':');
            var comma = body.index_of_char (',');
            int split_at = -1;
            if (colon >= 0 && comma >= 0) split_at = int.min (colon, comma);
            else if (colon >= 0) split_at = colon;
            else if (comma >= 0) split_at = comma;
            if (split_at < 0) {
                id = body.strip ();
            } else {
                id = body.substring (0, split_at).strip ();
                rest = body.substring (split_at + 1).strip ();
            }
            if (id.length == 0) continue;
            bool id_ok = true;
            for (var k = 0; k < id.length; k++) {
                if (!is_voice_id_char (id[k])) { id_ok = false; break; }
            }
            if (!id_ok) continue;
            if (rest.length == 0) {
                // Bare declaration @[v3]: id exists, no names. Only set if
                // not already defined so a later full def wins; an earlier
                // full def is kept (don't overwrite with empty).
                string? have_display = displays.lookup (id);
                string? have_credit = credits.lookup (id);
                if (have_display == null && have_credit == null) {
                    displays.set (id, "");
                }
                continue;
            }
            // One separator per line: unquoted ',' selects the canonical
            // comma form (@[v1,"Glinda","Credit",type=person]); otherwise the
            // legacy pipe form (@[v1:Glinda|"Credit"|type=person]). Quoted
            // sections are honoured either way. A legacy display containing
            // a literal comma must be quoted.
            char sep = '|';
            {
                bool q_single = false;
                bool q_double = false;
                for (var k = 0; k < rest.length; k++) {
                    var c = rest[k];
                    if (c == '\'' && !q_double) q_single = !q_single;
                    else if (c == '"' && !q_single) q_double = !q_double;
                    else if (c == ',' && !q_single && !q_double) { sep = ','; break; }
                }
            }
            string[] tokens = {};
            var cur = new StringBuilder ();
            bool in_single = false;
            bool in_double = false;
            for (var k = 0; k < rest.length; k++) {
                var c = rest[k];
                if (c == '\'' && !in_double) in_single = !in_single;
                else if (c == '"' && !in_single) in_double = !in_double;
                if (c == sep && !in_single && !in_double) {
                    tokens += cur.str;
                    cur = new StringBuilder ();
                    continue;
                }
                cur.append_c (c);
            }
            tokens += cur.str;
            // Positional name/credit plus an optional type= token in any
            // slot: @[v1000,type=group], @[v1,"Glinda","Kristin Chenoweth",type=person].
            // A quoted "type=X" stays literal text; only a bare token counts.
            string display = "";
            string credit = "";
            string vtype = "";
            string[] positional = {};
            foreach (var raw_tok in tokens) {
                var t = raw_tok.strip ();
                bool quoted = t.length >= 2 &&
                    ((t[0] == '"' && t[t.length - 1] == '"') ||
                     (t[0] == '\'' && t[t.length - 1] == '\''));
                if (!quoted && t.down ().has_prefix ("type=")) {
                    var tv = t.substring (5).strip ();
                    if (tv.length > 0 && vtype.length == 0) vtype = tv.down ();
                    continue;
                }
                positional += raw_tok;
            }
            if (positional.length > 0) display = decode_html_entities (strip_quotes (positional[0]));
            if (positional.length > 1) credit = decode_html_entities (strip_quotes (positional[1]));
            if (display.length > 0) displays.set (id, display);
            else {
                string? have_display = displays.lookup (id);
                if (have_display == null) displays.set (id, "");
            }
            if (credit.length > 0) credits.set (id, credit);
            if (vtype.length > 0) types.set (id, vtype);
        }
    }

    private string quote_voice_token (string s) {
        if (s.length == 0) return s;
        if (s.contains ("|") || s.contains (",") || s.contains ("]") || s.contains ("\"") ||
            s.has_prefix (" ") || s.has_suffix (" ") || s.contains ("  ")) {
            return "\"%s\"".printf (s.replace ("\"", "&quot;"));
        }
        // Quote tokens containing spaces so @[v1,"Kristin Chenoweth",type=person]
        // stays a single token on read.
        if (s.contains (" ")) return "\"%s\"".printf (s);
        return s;
    }

    // ── Section markers ([Chorus]) ────────────────────────────────────
    // Bare [Name] lines carry the song structure (TTML div songPart,
    // Paxsenix plain [Intro]/[Verse]/[Chorus] headers). They are format
    // metadata, not lyrics: legacy players fail the timestamp parse and
    // skip them, the LRC+ parser folds them into LyricLine.section, and
    // the renderer intentionally ignores them.

    private string? parse_section_marker (string line) {
        var ls = line.strip ();
        if (!ls.has_prefix ("[") || !ls.has_suffix ("]")) return null;
        var inner = ls.substring (1, ls.length - 2).strip ();
        if (inner.length == 0) return null;
        if (inner.contains (":") || inner.contains (".") || inner.contains ("<") ||
            inner.contains ("@") || inner.contains ("{") || inner.contains ("}")) return null;
        if (parse_timestamp (inner) >= 0) return null;
        var key = inner.down ().replace (" ", "").replace ("-", "").replace ("_", "");
        switch (key) {
            case "intro": return "Intro";
            case "verse": return "Verse";
            case "chorus": return "Chorus";
            case "bridge": return "Bridge";
            case "outro": return "Outro";
            case "hook": return "Hook";
            case "refrain": return "Refrain";
            case "prechorus": return "Pre-Chorus";
            case "postchorus": return "Post-Chorus";
            case "interlude": return "Interlude";
            case "instrumental": return "Instrumental";
            case "solo": return "Solo";
            case "breakdown": return "Breakdown";
            case "buildup": return "Buildup";
            case "drop": return "Drop";
            case "prelude": return "Prelude";
            case "postlude": return "Postlude";
            case "coda": return "Coda";
            case "vamp": return "Vamp";
            case "tag": return "Tag";
            case "reprise": return "Reprise";
            case "overture": return "Overture";
            case "finale": return "Finale";
            case "prologue": return "Prologue";
            case "epilogue": return "Epilogue";
            case "skit": return "Skit";
            default: return null;
        }
    }

    // ── Word joining (syllable-aware) ─────────────────────────────────
    // Display text is words joined with " " at word starts, "" for syllable
    // continuations. Mirrors the TTML/ELRC source encoding.

    public string join_lyric_words (LyricWord[] words) {
        var sb = new StringBuilder ();
        for (var i = 0; i < words.length; i++) {
            if (i > 0 && words[i].word_start) sb.append_c (' ');
            sb.append (words[i].text);
        }
        return sb.str;
    }

    // ── v2 timestamp pair ─────────────────────────────────────────────
    // Canonical separator is ','  (<00:01.31,00:01.66>); '|' accepted;
    // legacy double-colon (<00:01.31:00:01.66>) accepted on read.

    private bool parse_v2_timestamp_pair (string inside, out int64 start_ms, out int64 end_ms) {
        start_ms = -1; end_ms = -1;
        string? start_ts = null;
        string? end_ts = null;
        if (inside.contains (",")) {
            var parts = inside.split (",", 2);
            if (parts.length == 2) { start_ts = parts[0].strip (); end_ts = parts[1].strip (); }
        } else if (inside.contains ("|")) {
            var parts = inside.split ("|", 2);
            if (parts.length == 2) {
                var a = parts[0].strip ();
                var b = parts[1].strip ();
                // Only treat as pair if both sides are timestamps (v1 bulk
                // also uses '|' but starts with word text, not digits).
                if (a.length > 0 && a[0].isdigit () && parse_timestamp (a) >= 0 &&
                    b.length > 0 && parse_timestamp (b) >= 0) {
                    start_ts = a; end_ts = b;
                } else {
                    return false;
                }
            }
        } else {
            var parts = inside.split (":");
            if (parts.length == 4) {
                start_ts = "%s:%s".printf (parts[0], parts[1]);
                end_ts = "%s:%s".printf (parts[2], parts[3]);
            } else if (parts.length == 2) {
                start_ms = parse_timestamp (inside);
                return start_ms >= 0;
            } else {
                return false;
            }
        }
        if (start_ts == null || end_ts == null) return false;
        start_ms = parse_timestamp ((!)start_ts);
        end_ms = parse_timestamp ((!)end_ts);
        return start_ms >= 0 && end_ms >= 0;
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
            if (val.length == 0) {
                // Bare token with no value, e.g. the "v2" in {v2|style:bold}:
                // treat as voice shorthand unless it is a known key name.
                // (Pure {v2} is handled by the alias rule above; this covers
                // the mixed short+KV form on write.)
                if (voice.length == 0) {
                    var bare = strip_quotes (kv[0].strip ());
                    bool bare_ok = bare.length > 0;
                    for (var k = 0; bare_ok && k < bare.length; k++) {
                        if (!is_voice_id_char (bare[k])) bare_ok = false;
                    }
                    switch (bare.down ()) {
                        case "voice": case "display": case "name": case "label":
                        case "agent-name": case "style": case "effect":
                        case "lang": case "color":
                            bare_ok = false;
                            break;
                        default: break;
                    }
                    if (bare_ok) voice = bare;
                }
                continue;
            }
            switch (key) {
                case "voice": {
                    // Support voice:id[,Display] or voice:id,"Display" -> split on comma
                    var parts = val.split (",", 2);
                    voice = strip_quotes (parts[0].strip ());
                    if (parts.length > 1) {
                        var disp = decode_html_entities (strip_quotes (parts[1].strip ()));
                        if (disp.length > 0) voice_display = disp;
                    }
                    break;
                }
                case "display":
                case "name":
                case "label":
                case "agent-name": {
                    voice_display = decode_html_entities (strip_quotes (val));
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
                // "v1" is the default voice: normalize to "" so {v1},
                // {voice:v1} and untagged lines share one canonical id
                // (matches the TTML importer, which maps agent v1 to "").
                if (voice == "v1") voice = "";
                text_without_block = rest.substring (tag_end + 1).strip ();
            }
        }
    }

    // ── Timing-line attr blocks ─────────────────────────────────────
    //
    // Voice/styling tags live ONLY on the word-timing line, never on the
    // header, so legacy players (which read [mm:ss.xx]Text and skip
    // everything else) always see clean text:
    //   [00:10.00]Hello world
    //   {v1}<00:10.00,00:10.32>Hello <00:10.33,00:10.80>world
    // The leading block uses the same attr grammar as header blocks
    // ({v1} alias, {v1|style:bold}); only the FIRST block — before the
    // first '<' — is line-level, blocks after a '>' stay per-word.

    private string? timing_units_part (string line) {
        // Returns the units substring of a timing line (after the optional
        // leading {…} block), or null if the line is not timing-shaped.
        var ls = line.strip ();
        if (ls.has_prefix ("<")) return ls;
        if (ls.has_prefix ("{")) {
            var tag_end = ls.index_of_char ('}');
            if (tag_end >= 0) {
                var units = ls.substring (tag_end + 1).strip ();
                if (units.has_prefix ("<")) return units;
            }
        }
        return null;
    }

    private void parse_timing_attr_block (string timing_line,
                                          out string voice, out string voice_display,
                                          out string style, out string effect, out string lang,
                                          out string units) {
        voice = ""; voice_display = ""; style = ""; effect = ""; lang = "";
        units = timing_line.strip ();
        var ls = units;
        if (ls.has_prefix ("{")) {
            var tag_end = ls.index_of_char ('}');
            if (tag_end >= 0) {
                var inner = ls.substring (1, tag_end - 1);
                parse_attr_block (inner, out voice, out voice_display, out style, out effect, out lang);
                // "v1" is the default voice: normalize to "" (same rule as
                // parse_lrc_plus_header_attrs) so all spellings unify.
                if (voice == "v1") voice = "";
                units = ls.substring (tag_end + 1).strip ();
            }
        }
    }

    private bool looks_like_v2_timing_line (string line) {
        // Timing lines may carry a leading {…} voice/style block; the
        // timestamp check runs on the units part after it.
        var units = timing_units_part (line);
        if (units == null) return false;
        var ls = (!)units;
        var gt = ls.index_of_char ('>');
        if (gt < 0) return false;
        var inside = ls.substring (1, gt - 1).strip ();
        if (inside.length == 0) return false;
        // v1 bulk contains '|' with word text; v2 inside starts with a digit
        if (inside.contains ("|") && !inside[0].isdigit ()) return false;
        if (!inside[0].isdigit ()) return false;
        // single timestamp e.g. "00:10.00" (start only, end inferred)
        if (parse_timestamp (inside) >= 0) return true;
        // pair: canonical "00:10.00,00:10.32", also '|' and legacy ':'
        int64 s, e;
        return parse_v2_timestamp_pair (inside, out s, out e);
    }

    public LyricWord[] parse_word_timings_v2 (string timing_line, int64 line_end_ms = -1) {
        LyricWord[] words = {};
        // track whether end was explicitly supplied per word
        bool[] has_explicit_end = {};
        var rest = timing_line.strip ();
        var pos = 0;
        // Syllable rule: space separates words, adjacency means same word.
        // The boundary before the current unit was decided by the previous
        // unit's trailing space; a leading space after '>' also opens a word.
        bool next_starts_word = true;
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
            // inside may be "00:10.00" (start only) or a start,end pair:
            // canonical "00:10.00,00:10.32", also "00:10.00|00:10.32" and
            // legacy "00:10.00:00:10.32".
            if (parse_timestamp (inside) >= 0) {
                start_ms = parse_timestamp (inside);
            } else {
                int64 ps, pe;
                if (parse_v2_timestamp_pair (inside, out ps, out pe)) {
                    start_ms = ps;
                    end_ms = pe;
                    explicit_end = end_ms >= 0;
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
            var word_begin = pos;
            var next_lt = rest.index_of_char ('<', pos);
            string raw_slice;
            if (next_lt < 0) {
                raw_slice = rest.substring (word_begin);
                pos = rest.length;
            } else {
                raw_slice = rest.substring (word_begin, next_lt - word_begin);
                pos = next_lt;
            }
            bool leading_space = raw_slice.length > 0 && raw_slice[0].isspace ();
            bool trailing_space = raw_slice.length > 0 && raw_slice[raw_slice.length - 1].isspace ();
            var word_text = decode_html_entities (raw_slice.strip ());
            if (word_text.length == 0 || start_ms < 0) continue;
            bool this_word_start = next_starts_word || leading_space;
            next_starts_word = trailing_space;
            double s = start_ms / 1000.0;
            // if no explicit end, use sentinel -1 to allow inference
            double e = explicit_end ? end_ms / 1000.0 : -1.0;
            LyricWord w = { word_text, s, e, w_style, w_effect, this_word_start };
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

        // File-level voice table: @[v2,"Elphaba","Idina Menzel",type=person]
        HashTable<string,string> voice_displays;
        HashTable<string,string> voice_credits;
        HashTable<string,string> voice_types;
        parse_voice_defs (lrc, out voice_displays, out voice_credits, out voice_types);

        LyricLine[] result = {};
        var raw_lines = strip_lrc_metadata (lrc).split ("\n");
        // Song-section context from bare [Chorus] markers (TTML songPart).
        string current_section = "";
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
            if (ms < 0) {
                // Bare [Chorus]-style section marker: sets context for the
                // lines that follow, never becomes a lyric line itself.
                string? sect = parse_section_marker (line);
                if (sect != null) current_section = (!)sect;
                continue;
            }

            var decoded_rest = decode_html_entities (text_part);

            LyricWord[] words = {};
            bool has_timing = false;
            string? units_next = (i < raw_lines.length) ? timing_units_part (raw_lines[i]) : null;
            if (units_next != null) {
                var timing_line = raw_lines[i].strip ();
                // Voice/style tags live on the timing line (headers stay
                // bare for legacy players). Split the leading {…} block.
                string t_voice, t_display, t_style, t_effect, t_lang, units;
                parse_timing_attr_block (timing_line, out t_voice, out t_display, out t_style, out t_effect, out t_lang, out units);
                if (looks_like_v2_timing_line (units)) {
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
                    words = parse_word_timings_v2 (units, line_end_ms);
                } else {
                    words = parse_word_timings (units);
                }
                has_timing = words.length > 0;
                // Merge: timing-line block wins per field; the header block
                // is back-compat fallback for files written before the move.
                if (t_voice.length > 0) voice_role = t_voice;
                if (t_display.length > 0) voice_display = t_display;
                if (t_style.length > 0) style = t_style;
                if (t_effect.length > 0) effect = t_effect;
                if (t_lang.length > 0) lang = t_lang;
                // Consume the timing line even if its units parsed empty.
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
            // Resolve pretty names from the file-level voice table when the
            // short {v2} tag carries no inline display. Inline display
            // ({voice:v2|display:X}, back-compat read) wins if present.
            // Untagged timed lines sing the default voice, so they inherit
            // the v1 table entry (this is what makes @[v1:...] round-trip
            // through tagless headers). Untimed lines carry no voice.
            string voice_credit = "";
            string voice_type = "";
            if (voice_role.length > 0) {
                if (voice_display.length == 0) {
                    string? d = voice_displays.lookup (voice_role);
                    if (d != null) voice_display = (!)d;
                }
                string? c = voice_credits.lookup (voice_role);
                if (c != null) voice_credit = (!)c;
                string? t = voice_types.lookup (voice_role);
                if (t != null) voice_type = (!)t;
            } else if (has_timing) {
                string? d = voice_displays.lookup ("v1");
                if (d != null) voice_display = (!)d;
                string? c = voice_credits.lookup ("v1");
                if (c != null) voice_credit = (!)c;
                string? t = voice_types.lookup ("v1");
                if (t != null) voice_type = (!)t;
            }

            LyricLine l = { ms, decoded_rest, words, voice_role, voice_display, style, effect, lang, voice_credit, voice_type, current_section };
            result += l;
        }
        return split_bracket_backgrounds (deduplicate_lines (result));
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

    private LyricLine[] split_bracket_backgrounds (LyricLine[] input) {
        // Auto-detect bracketed text e.g. "Hello (All we see is light) world"
        // and split into independent voice lines: main + bg (voice=bg).
        LyricLine[] out = {};
        foreach (var l in input) {
            var text = l.text;
            if (!text.contains ("(") || !text.contains (")")) {
                out += l;
                continue;
            }
            int[] opens = {};
            int[] closes = {};
            string[] bg_parts = {};
            int search_from = 0;
            while (true) {
                int o = text.index_of ("(", search_from);
                if (o < 0) break;
                int c = text.index_of (")", o + 1);
                if (c < 0) break;
                opens += o;
                closes += c;
                var inner = text.substring (o + 1, c - o - 1).strip ();
                if (inner.length > 0) bg_parts += inner;
                search_from = c + 1;
            }
            if (bg_parts.length == 0) {
                out += l;
                continue;
            }
            // If already bg, just strip parentheses
            if (l.voice_role == "bg") {
                string cleaned = text.replace ("(", "").replace (")", "").strip ();
                while (cleaned.contains ("  ")) cleaned = cleaned.replace ("  ", " ");
                LyricLine nl = l;
                nl.text = cleaned;
                for (var wi = 0; wi < nl.words.length; wi++) {
                    nl.words[wi].text = nl.words[wi].text.replace ("(", "").replace (")", "").strip ();
                }
                LyricWord[] filtered = {};
                foreach (var w in nl.words) if (w.text.length > 0) filtered += w;
                nl.words = filtered;
                out += nl;
                continue;
            }
            string bg_text = "";
            for (var k = 0; k < bg_parts.length; k++) {
                if (k > 0) bg_text += " ";
                bg_text += bg_parts[k];
            }
            var main_sb = new StringBuilder ();
            int pos = 0;
            for (var k = 0; k < opens.length; k++) {
                main_sb.append (text.substring (pos, opens[k] - pos));
                pos = closes[k] + 1;
            }
            main_sb.append (text.substring (pos));
            string main_text = main_sb.str.strip ();
            while (main_text.contains ("  ")) main_text = main_text.replace ("  ", " ");
            if (main_text.length == 0) {
                LyricLine bg = l;
                bg.text = bg_text;
                bg.voice_role = "bg";
                bg.voice_display = "";
                for (var wi = 0; wi < bg.words.length; wi++) {
                    bg.words[wi].text = bg.words[wi].text.replace ("(", "").replace (")", "").strip ();
                }
                LyricWord[] filtered = {};
                foreach (var w in bg.words) if (w.text.length > 0) filtered += w;
                bg.words = filtered;
                out += bg;
                continue;
            }
            if (l.words.length == 0) {
                LyricLine main = l;
                main.text = main_text;
                out += main;
                LyricLine bg = { l.time_ms, bg_text, {}, "bg", "", "", "", "", "", "", l.section };
                out += bg;
                continue;
            }
            // Partition words by position in original text
            LyricWord[] main_words = {};
            LyricWord[] bg_words = {};
            int text_pos = 0;
            foreach (var w in l.words) {
                string clean = w.text.replace ("(", "").replace (")", "").strip ();
                if (clean.length == 0) continue;
                int found = -1;
                // naive forward search for clean starting at text_pos
                for (int s = text_pos; s + clean.length <= text.length; s++) {
                    if (text.substring (s, clean.length) == clean) {
                        found = s;
                        break;
                    }
                }
                bool inside = false;
                if (found >= 0) {
                    for (var k = 0; k < opens.length; k++) {
                        if (found > opens[k] && found < closes[k]) { inside = true; break; }
                        if (found >= opens[k] && found + clean.length <= closes[k] + 1) { inside = true; break; }
                    }
                    text_pos = found + clean.length;
                } else {
                    if (bg_text.contains (clean)) inside = true;
                    else if (main_text.contains (clean)) inside = false;
                    else inside = false;
                }
                LyricWord nw = w;
                nw.text = clean;
                if (inside) bg_words += nw;
                else main_words += nw;
            }
            if (main_words.length == 0 || bg_words.length == 0) {
                main_words = {};
                bg_words = {};
                foreach (var w in l.words) {
                    string clean = w.text.replace ("(", "").replace (")", "").strip ();
                    if (clean.length == 0) continue;
                    bool in_bg = bg_text.contains (clean);
                    bool in_main = main_text.contains (clean);
                    LyricWord nw = w; nw.text = clean;
                    if (in_bg && !in_main) bg_words += nw;
                    else if (in_main && !in_bg) main_words += nw;
                    else if (in_bg && in_main) {
                        // ambiguous: use first occurrence heuristic
                        int idx_bg = bg_text.index_of (clean);
                        int idx_main = main_text.index_of (clean);
                        if (idx_bg >= 0 && idx_main < 0) bg_words += nw;
                        else main_words += nw;
                    } else {
                        main_words += nw;
                    }
                }
            }
            if (main_words.length == 0 || bg_words.length == 0) {
                main_words = {};
                bg_words = {};
                int half = l.words.length / 2;
                for (int wi = 0; wi < l.words.length; wi++) {
                    string clean = l.words[wi].text.replace ("(", "").replace (")", "").strip ();
                    if (clean.length == 0) continue;
                    LyricWord nw = l.words[wi];
                    nw.text = clean;
                    if (wi < half) main_words += nw;
                    else bg_words += nw;
                }
                if (main_words.length == 0 && bg_words.length > 0) {
                    main_words += bg_words[0];
                    LyricWord[] tmp = {};
                    for (int i = 1; i < bg_words.length; i++) tmp += bg_words[i];
                    bg_words = tmp;
                }
            }
            LyricWord[] f_main = {};
            foreach (var w in main_words) if (w.text.length > 0) f_main += w;
            LyricWord[] f_bg = {};
            foreach (var w in bg_words) if (w.text.length > 0) f_bg += w;
            // Slice heads always start a new display word even if the unit
            // was a syllable continuation in the original line.
            if (f_main.length > 0) f_main[0].word_start = true;
            if (f_bg.length > 0) f_bg[0].word_start = true;
            LyricLine main_line = { l.time_ms, main_text, f_main, l.voice_role, l.voice_display, l.style, l.effect, l.lang, l.voice_credit, l.voice_type, l.section };
            LyricLine bg_line = { l.time_ms, bg_text, f_bg, "bg", "", "", "", "", "", "", l.section };
            if (main_line.text.length > 0) out += main_line;
            if (bg_line.text.length > 0) out += bg_line;
            if (main_line.text.length == 0 && bg_line.text.length == 0) out += l;
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
                    // "v1" is the default voice (see parse_lrc_plus_header_attrs)
                    if (voice_role == "v1") voice_role = "";
                    rest = rest.substring (first_tag);
                } else {
                    rest = rest.substring (first_tag);
                }
            }

            LyricWord[] words = {};
            var pos = 0;
            // Syllable rule (matches TTML/ELRC source encoding): a space
            // between units separates words (<…>An<…>y = one word "Any"),
            // so the boundary before each unit comes from the previous
            // segment's trailing space, or leading space after '>'.
            bool next_starts_word = true;

            while (pos < rest.length) {
                if (rest[pos] == '<') {
                    var end = rest.index_of_char ('>', pos);
                    if (end < 0) break;
                    var ts_str = rest.substring (pos + 1, end - pos - 1);
                    var word_start_ms = parse_timestamp (ts_str);
                    pos = end + 1;

                    var seg_begin = pos;
                    while (pos < rest.length && rest[pos] != '<')
                        pos++;
                    var raw_seg = rest.substring (seg_begin, pos - seg_begin);
                    bool leading_space = raw_seg.length > 0 && raw_seg[0].isspace ();
                    bool trailing_space = raw_seg.length > 0 && raw_seg[raw_seg.length - 1].isspace ();
                    var word_text = decode_html_entities (raw_seg.strip ());

                    if (word_text.length > 0 && word_start_ms >= 0) {
                        bool this_word_start = next_starts_word || leading_space;
                        next_starts_word = trailing_space;
                        LyricWord w = { word_text, word_start_ms / 1000.0, 0.0, "", "", this_word_start };
                        words += w;
                    } else if (word_text.length == 0 && word_start_ms >= 0) {
                        // Bare end-time tag (e.g. trailing <00:03.394>):
                        // no word, leaves the pending boundary untouched.
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

            // Display text joins syllable continuations without spaces so
            // "An<…>y<…>m<…>ore" renders "Anymore", not "An y m ore".
            var line_text = words.length > 0 ? join_lyric_words (words) : "";
            LyricLine l = { line_ms, line_text, words, voice_role, "", "", "", "", "", "", "" };
            result += l;
        }
        return split_bracket_backgrounds (deduplicate_lines (result));
    }

    public LyricLine[] parse_lrc (string lrc) {
        LyricLine[] result = {};
        HashTable<string,string> voice_displays;
        HashTable<string,string> voice_credits;
        HashTable<string,string> voice_types;
        parse_voice_defs (lrc, out voice_displays, out voice_credits, out voice_types);
        var raw_lines = strip_lrc_metadata (lrc).split ("\n");
        // Song-section context from bare [Chorus] markers (see parse_lrc_plus).
        string current_section = "";
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
                    // "v1" is the default voice (see parse_lrc_plus_header_attrs)
                    if (voice_role == "v1" || voice_role == "voice:v1") voice_role = "";
                    rest = rest.substring (tag_end + 1).strip ();
                }
            }

            var ms = parse_timestamp (timestamp);
            if (ms < 0) {
                // Bare [Chorus]-style section marker: sets context for the
                // lines that follow, never becomes a lyric line itself.
                string? sect = parse_section_marker (line);
                if (sect != null) current_section = (!)sect;
                continue;
            }

            LyricWord[] words = {};
            string? units_next = (i < raw_lines.length) ? timing_units_part (raw_lines[i]) : null;
            if (units_next != null) {
                // Timing-line {…} block carries the voice (headers stay bare).
                string t_voice, t_display, t_style, t_effect, t_lang, units;
                parse_timing_attr_block (raw_lines[i].strip (), out t_voice, out t_display, out t_style, out t_effect, out t_lang, out units);
                if (t_voice.length > 0) voice_role = t_voice;
                words = parse_word_timings (units);
                // strict isolation: if no words parsed, drop legacy voice on plain LRC line
                if (words.length == 0)
                    voice_role = "";
                else
                    i++;
            } else {
                voice_role = "";
            }

            var decoded_rest = decode_html_entities (rest);
            // Resolve the agent type from the voice table so the badge can
            // fall back to it (nameless v1000 etc.). Display stays unset on
            // this lenient path; untagged timed lines inherit the v1 type.
            string voice_type = "";
            if (voice_role.length > 0) {
                string? t = voice_types.lookup (voice_role);
                if (t != null) voice_type = (!)t;
            } else if (words.length > 0) {
                string? t = voice_types.lookup ("v1");
                if (t != null) voice_type = (!)t;
            }
            LyricLine l = { ms, decoded_rest, words, voice_role, "", "", "", "", "", voice_type, current_section };
            result += l;
        }
        return split_bracket_backgrounds (deduplicate_lines (result));
    }

    public LyricLine[] parse_plain (string text) {
        LyricLine[] result = {};
        foreach (var line in text.split ("\n")) {
            var trimmed = line.strip ();
            // Voice-table lines are file-level metadata, never lyric text
            // (section headers like [Chorus] are kept as plain lines).
            if (trimmed.has_prefix ("[@") || trimmed.has_prefix ("@[")) continue;
            if (trimmed.length > 0 && trimmed[0] == '[' && parse_timestamp (
                    trimmed.substring (1, trimmed.index_of_char (']') > 0
                        ? trimmed.index_of_char (']') - 1 : 0)) >= 0)
                continue;
            LyricWord[] empty_words = {};
            LyricLine l = { -1, trimmed, empty_words, "", "", "", "", "", "", "", "" };
            result += l;
        }
        var start = 0;
        var end = result.length - 1;
        while (start <= end && result[start].text.length == 0) start++;
        while (end >= start && result[end].text.length == 0) end--;
        var sliced = result[start:end + 1];
        return split_bracket_backgrounds (sliced);
    }

    // ── TTML agent pretty-name extraction ───────────────────────────────
    private HashTable<string,string> extract_ttml_agents (Xml.Node* root, out HashTable<string,string> types) {
        var agents = new HashTable<string,string> (str_hash, str_equal);
        types = new HashTable<string,string> (str_hash, str_equal);
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
                        // Agent kind (person|group): recorded even when the
                        // agent has no name, so nameless v1000/v3 still get
                        // a nametable entry (@[v1000,type=group]).
                        string? atype = n->get_prop ("type");
                        if (atype != null && ((!)atype).strip ().length > 0)
                            types.set ((!)id, ((!)atype).strip ().down ());
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

    private string agent_type_for (HashTable<string,string> types, string voice_role) {
        if (voice_role.length == 0) return "";
        if (voice_role == "bg") return "";
        string? v = types.lookup (voice_role);
        if (v != null) return (!)v;
        v = types.lookup (voice_role.down ());
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

        HashTable<string,string> agent_types;
        var agents = extract_ttml_agents (root, out agent_types);
        LyricLine[] ttml_result;
        if (has_word_timing) {
            ttml_result = parse_ttml_word_synced (body, agents, agent_types);
        } else if (has_line_timing) {
            ttml_result = parse_ttml_line_synced (body, agents, agent_types);
        } else {
            ttml_result = parse_ttml_unsynced (body);
        }
        delete doc;
        return split_bracket_backgrounds (ttml_result);
    }

    private LyricLine[] parse_ttml_unsynced (Xml.Node* body) {
        LyricLine[] result = {};
        for (var div = body->children; div != null; div = div->next) {
            if (div->type != Xml.ElementType.ELEMENT_NODE) continue;
            string div_section = div->get_prop ("songPart") ?? "";
            div_section = div_section.strip ();
            for (var p = div->children; p != null; p = p->next) {
                if (p->type != Xml.ElementType.ELEMENT_NODE) continue;
                if (p->name != "p") continue;
                var text = p->get_content ();
                if (text.strip ().length > 0) {
                    LyricWord[] empty_words = {};
                    LyricLine l = { -1, text.strip (), empty_words, "", "", "", "", "", "", "", div_section };
                    result += l;
                }
            }
        }
        return result;
    }

    private LyricLine[] parse_ttml_line_synced (Xml.Node* body, HashTable<string,string>? agents = null, HashTable<string,string>? agent_types = null) {
        LyricLine[] result = {};
        for (var div = body->children; div != null; div = div->next) {
            if (div->type != Xml.ElementType.ELEMENT_NODE) continue;
            string div_section = div->get_prop ("songPart") ?? "";
            div_section = div_section.strip ();
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
                string voice_type = "";
                if (agents != null) {
                    // try raw agent id first (preserves v1 pretty name), fallback to role
                    string raw = p_agent ?? "";
                    voice_display = agent_display_for ((!)agents, raw);
                    if (voice_display.length == 0) voice_display = agent_display_for ((!)agents, voice_role);
                }
                if (agent_types != null) {
                    string raw = p_agent ?? "";
                    voice_type = agent_type_for ((!)agent_types, raw);
                    if (voice_type.length == 0) voice_type = agent_type_for ((!)agent_types, voice_role);
                }

                var p_content = p->get_content ();

                LyricWord[] main_words = {};
                LyricWord[] bg_words = {};
                // Syllable rule: TTML separates words with a space text node
                // between spans and glues syllables by adjacency
                // (<span>Def</span><span>y</span> = "Defy"). Whitespace text
                // nodes are significant here, so they are tracked instead of
                // skipped.
                bool pending_space = false;

                for (var span = p->children; span != null; span = span->next) {
                    if (span->type != Xml.ElementType.ELEMENT_NODE) {
                        if (ttml_node_is_space (span)) pending_space = true;
                        continue;
                    }
                    if (span->name != "span") continue;

                    var role = span->get_prop ("role");
                    bool is_this_bg = (role != null && (!)role == "x-bg");
                    var w_text = span->get_content ();

                    if (is_this_bg) {
                        bool bg_pending_space = false;
                        for (var ws = span->children; ws != null; ws = ws->next) {
                            if (ws->type != Xml.ElementType.ELEMENT_NODE) {
                                if (ttml_node_is_space (ws)) bg_pending_space = true;
                                continue;
                            }
                            var w_begin = ws->get_prop ("begin");
                            var w_end = ws->get_prop ("end");
                            var w_content = ws->get_content ();
                            if (w_begin != null && w_end != null && w_content.length > 0) {
                                bool starts = bg_words.length == 0 || bg_pending_space;
                                bg_pending_space = false;
                                LyricWord w = {
                                    w_content,
                                    ttml_time_to_ms ((!)w_begin) / 1000.0,
                                    ttml_time_to_ms ((!)w_end) / 1000.0,
                                    "", "", starts
                                };
                                bg_words += w;
                            }
                        }
                        pending_space = false;
                    } else {
                        var w_begin = span->get_prop ("begin");
                        var w_end = span->get_prop ("end");
                        if (w_begin != null && w_end != null && w_text.length > 0) {
                            bool starts = main_words.length == 0 || pending_space;
                            pending_space = false;
                            LyricWord w = {
                                w_text,
                                ttml_time_to_ms ((!)w_begin) / 1000.0,
                                ttml_time_to_ms ((!)w_end) / 1000.0,
                                "", "", starts
                            };
                            main_words += w;
                        }
                    }
                }

                // Display text joins syllable continuations without spaces so
                // "Def"+"y"+"ing" renders "Defying", not "Def y ing".
                var line_text = main_words.length > 0 ? join_lyric_words (main_words) : p_content.strip ();
                if (line_text.length == 0) continue;

                LyricLine main_line = { ms, line_text, main_words, voice_role, voice_display, "", "", "", "", voice_type, div_section };
                result += main_line;

                if (bg_words.length > 0) {
                    LyricLine bg_line = { ms, join_lyric_words (bg_words), bg_words, "bg", "", "", "", "", "", "", div_section };
                    result += bg_line;
                }
            }
        }
        return result;
    }

    private LyricLine[] parse_ttml_word_synced (Xml.Node* body, HashTable<string,string>? agents = null, HashTable<string,string>? agent_types = null) {
        LyricLine[] result = {};
        for (var div = body->children; div != null; div = div->next) {
            if (div->type != Xml.ElementType.ELEMENT_NODE) continue;
            string div_section = div->get_prop ("songPart") ?? "";
            div_section = div_section.strip ();
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
                // Same syllable rule as parse_ttml_line_synced: space text
                // nodes between spans separate words, adjacency glues.
                bool pending_space = false;

                for (var span = p->children; span != null; span = span->next) {
                    if (span->type != Xml.ElementType.ELEMENT_NODE) {
                        if (ttml_node_is_space (span)) pending_space = true;
                        continue;
                    }
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
                        bool bg_pending_space = false;
                        for (var ws = span->children; ws != null; ws = ws->next) {
                            if (ws->type != Xml.ElementType.ELEMENT_NODE) {
                                if (ttml_node_is_space (ws)) bg_pending_space = true;
                                continue;
                            }
                            var w_begin = ws->get_prop ("begin");
                            var w_end = ws->get_prop ("end");
                            var w_content = ws->get_content ();
                            if (w_begin != null && w_end != null && w_content.length > 0) {
                                bool starts = bg_words.length == 0 || bg_pending_space;
                                bg_pending_space = false;
                                LyricWord w = { w_content, ttml_time_to_ms ((!)w_begin) / 1000.0, ttml_time_to_ms ((!)w_end) / 1000.0, "", "", starts };
                                bg_words += w;
                            }
                        }
                        pending_space = false;
                    } else {
                        var w_begin_str = span->get_prop ("begin");
                        var w_end_str = span->get_prop ("end");
                        var w_text = span->get_content ();
                        if (w_begin_str != null && w_end_str != null && w_text.length > 0) {
                            var w_begin = ttml_time_to_ms ((!)w_begin_str);
                            var w_end = ttml_time_to_ms ((!)w_end_str);
                            if (w_begin >= 0 && w_end >= 0) {
                                bool starts = main_words.length == 0 || pending_space;
                                pending_space = false;
                                LyricWord w = { w_text, w_begin / 1000.0, w_end / 1000.0, "", "", starts };
                                main_words += w;
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
                string voice_type = "";
                if (agent_types != null) {
                    voice_type = agent_type_for ((!)agent_types, voice_role);
                    if (voice_type.length == 0 && last_agent.length > 0)
                        voice_type = agent_type_for ((!)agent_types, last_agent);
                }
                if (main_words.length > 0) {
                    LyricLine l = { line_ms, join_lyric_words (main_words), main_words, voice_role, voice_display, "", "", "", "", voice_type, div_section };
                    result += l;
                }

                if (bg_words.length > 0) {
                    LyricLine bg_line = { line_ms, join_lyric_words (bg_words), bg_words, "bg", "", "", "", "", "", "", div_section };
                    result += bg_line;
                }
            }
        }
        return result;
    }

    // ── Helpers ───────────────────────────────────────────────────────

    private int64 round_sec_to_ms (double sec) {
        // Round (not truncate) to nearest ms: 128.45 is not exactly
        // representable as a double, so (int64)(128.44999…*1000) would lose
        // 1 ms and drift by 1 cs on every serialize→parse cycle. All lyric
        // times are non-negative, so +0.5 truncation-rounding is exact here
        // and avoids pulling in libm.
        return (int64) (sec * 1000 + 0.5);
    }

    private bool ttml_node_is_space (Xml.Node* node) {
        var t = node->get_content ();
        return t.contains (" ") || t.contains ("\t") || t.contains ("\n") || t.contains ("\r");
    }

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
                // v1 bulk has no syllable encoding: each entry is a word.
                LyricWord w = { text, double.parse (segments[1]), double.parse (segments[2]), "", "", true };
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
            return round_sec_to_ms (h * 3600 + m * 60 + s);
        } else if (parts.length == 2) {
            var m = int.parse (parts[0]);
            var s = double.parse (parts[1]);
            return round_sec_to_ms (m * 60 + s);
        } else {
            return round_sec_to_ms (double.parse (t));
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
        // round to nearest ms (see round_sec_to_ms): truncating the inexact
        // double 128.45 would give 128449 and drift on serialize→parse
        int64 ms = round_sec_to_ms (sec);
        return format_ms_as_timestamp (ms);
    }

    public string encode_html_entities (string s) {
        return s.replace ("&", "&amp;")
                .replace ("<", "&lt;")
                .replace (">", "&gt;");
    }

    private string effective_voice_id (LyricLine l) {
        // The default voice ("", TTML v1 normalized) is written with the
        // explicit {v1} alias when the line carries a display name,
        // performer credit or agent type that belongs in the @[...] voice
        // table; otherwise it stays untagged (cleanest for legacy players).
        if (l.voice_role.length > 0) return l.voice_role;
        if (l.words.length > 0 && (l.voice_display.length > 0 || l.voice_credit.length > 0 || l.voice_type.length > 0))
            return "v1";
        return "";
    }

    private string build_timing_attr_block (LyricLine l) {
        // Line-level attrs are serialized ONLY on the timing line, never on
        // the header, so legacy players (which display [mm:ss.xx]Text and
        // skip '<'/'{' lines) always see clean text. Voice uses the short
        // {v1} alias only — pretty names live once per file in @[...] voice
        // table lines, never inline, so no {voice:...|display:...} metadata
        // leaks anywhere legacy players look.
        // (Inline long form is still accepted on read for back-compat.)
        if (l.words.length == 0) return "";
        var parts = new StringBuilder ();
        var vid = effective_voice_id (l);
        if (vid.length > 0) {
            parts.append (vid);
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

    private string serialize_voice_table (LyricLine[] lines) {
        // Ordered unique voice ids (first appearance) that carry a display
        // name, performer credit or agent type. One separator (','):
        // @[v2,"Elphaba","Idina Menzel",type=person] or @[v1000,type=group].
        // '@' leads so legacy '['-anchored players skip the line outright.
        // Ids with nothing known need no declaration.
        string[] seen = {};
        var sb = new StringBuilder ();
        foreach (var l in lines) {
            if (l.time_ms < 0) continue;
            var vid = effective_voice_id (l);
            if (vid.length == 0) continue;
            bool dup = false;
            foreach (var s in seen) if (s == vid) { dup = true; break; }
            if (dup) continue;
            if (l.voice_display.length == 0 && l.voice_credit.length == 0 && l.voice_type.length == 0) continue;
            seen += vid;
            string ds = l.voice_display.length > 0 ? quote_voice_token (encode_html_entities (l.voice_display)) : "";
            string cs = l.voice_credit.length > 0 ? quote_voice_token (encode_html_entities (l.voice_credit)) : "";
            // Positional slots: name, credit — then the type= key. Empty
            // slots are kept only when a later slot is filled:
            // @[v1,Glinda], @[v1,,"Credit",type=person], @[v1000,type=group].
            var rest = new StringBuilder ();
            if (ds.length == 0 && cs.length == 0) {
                // Type-only declaration: @[v1000,type=group]
                rest.append ("type=%s".printf (l.voice_type));
            } else {
                rest.append (ds);
                if (cs.length > 0) {
                    rest.append_c (',');
                    rest.append (cs);
                }
                if (l.voice_type.length > 0) {
                    if (rest.len > 0) rest.append_c (',');
                    rest.append ("type=%s".printf (l.voice_type));
                }
            }
            sb.append ("@[%s,%s]\n".printf (vid, rest.str));
        }
        return sb.str;
    }

    public string serialize_to_lrc_plus (LyricLine[] lines) {
        var sb = new StringBuilder ();
        sb.append (serialize_voice_table (lines));
        // Song-section context: emit a bare [Chorus] marker when the section
        // changes. Legacy players fail the timestamp parse and skip it;
        // the parser folds it back into LyricLine.section; the renderer
        // ignores it.
        string last_section = "";
        foreach (var l in lines) {
            if (l.time_ms < 0) continue;
            if (l.section.length > 0 && l.section != last_section) {
                sb.append ("[%s]\n".printf (l.section));
                last_section = l.section;
            } else if (l.section.length == 0) {
                last_section = "";
            }
            // Headers are ALWAYS bare [mm:ss.xx]Text — no {…} block ever —
            // so legacy players print clean lyrics verbatim.
            sb.append ("[%s]".printf (format_ms_as_timestamp (l.time_ms)));
            sb.append (encode_html_entities (l.text));
            sb.append_c ('\n');

            if (l.words.length > 0) {
                // v2 inline Variant A absolute with comma separator:
                // {v1}<mm:ss.xx,mm:ss.xx>Word — comma avoids the 4-colon
                // confusion of <00:01.31:00:01.66>. The {…} voice/style
                // block leads the timing line (which legacy players skip).
                // Space separates words; no space glues syllables:
                // {v2}<01:53.50,01:53.70>Def<01:53.70,01:54.96>y<…>ing <…>gravity
                var block = build_timing_attr_block (l);
                if (block.length > 0)
                    sb.append (block);
                for (var wi = 0; wi < l.words.length; wi++) {
                    var w = l.words[wi];
                    var start_ts = format_sec_as_timestamp (w.start_sec);
                    var end_ts = format_sec_as_timestamp (w.end_sec);
                    sb.append ("<%s,%s>".printf (start_ts, end_ts));
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
                    sb.append (encode_html_entities (w.text));
                    // Space separates words; syllable continuations glue.
                    if (wi + 1 < l.words.length && l.words[wi + 1].word_start)
                        sb.append_c (' ');
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
