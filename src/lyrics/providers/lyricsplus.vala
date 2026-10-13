namespace G4 {

    // LyricsPlus aggregates Apple, Spotify, QQ and Deezer lyrics.
    // NOTE: musixmatch / musixmatch-word are deliberately NOT requested:
    // their phrase-level entries were re-chunked as word timings and
    // poisoned scoring, and both endpoints are chronically rate-limited
    // (1027) or 404 on the mirrors. Musixmatch is covered by the
    // dedicated Musixmatch provider instead.
    private const string LYRICSPLUS_SOURCES = "apple,lyricsplus,spotify,qq,deezer";

    public async LyricsCandidate? provider_fetch_lyricsplus (Music music, int duration_ms, Settings settings, int index, GLib.Cancellable? cancellable = null) {
        if (!settings.get_boolean ("lyrics-lyricsplus-enabled")) {
            lyrics_log ("LyricsPlus: disable");
            return null;
        }

        var title = music.title.strip ();
        var artist = music.artist.strip ();
        if (title.length == 0 || artist.length == 0) {
            if (lyrics_debug_enabled)
                lyrics_log ("LyricsPlus: empty title/artist, skipping");
            return null;
        }

        var duration_sec = (int) (duration_ms / 1000);
        string[] base_urls = {
            "https://lyricsplus.prjktla.workers.dev",
            "https://lyricsplus.prjktla.my.id",
            "https://lyricsplus.binimum.org"
        };
        string? result = null;
        foreach (var base_url in base_urls) {
            if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
            var url = "%s/v2/lyrics/get?title=%s&artist=%s&duration=%d&source=%s".printf (
                base_url,
                Uri.escape_string (title, null, false),
                Uri.escape_string (artist, null, false),
                duration_sec,
                LYRICSPLUS_SOURCES);
            if (music.album.strip ().length > 0)
                url += "&album=%s".printf (Uri.escape_string (music.album.strip (), null, false));
            for (var attempt = 0; attempt < 3; attempt++) {
                if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
                var body = yield lyrics_http_get_with_headers_allow_4xx (url, { { "User-Agent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" } }, cancellable);
                if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
                if (body == null) break; // mirror down: try next mirror
                var raw = (!)body;
                if (raw.contains ("error code: 1027")) {
                    // Rate limited: back off, then retry (cancellable-aware)
                    yield lyricsplus_sleep_ms (1000 * (attempt + 1), cancellable);
                    continue;
                }
                if (raw.contains ("error code: 1033"))
                    break; // hard block on this mirror: try next mirror
                if (raw.length > 0) {
                    result = lyricsplus_parse_response (raw);
                    // null = transport/JSON error (retry same mirror);
                    // "" = valid miss (try next mirror); else got lyrics.
                    if (result == null) {
                        if (lyrics_debug_enabled)
                            lyrics_log ("LyricsPlus: unparseable response from %s".printf (base_url));
                        break;
                    }
                    if (((!)result).length == 0) {
                        if (lyrics_debug_enabled)
                            lyrics_log ("LyricsPlus: no lyrics at %s".printf (base_url));
                        result = null;
                        break;
                    }
                    break;
                }
                break;
            }
            if (result != null && ((!)result).length > 0) break;
            result = null;
        }
        if (result != null && ((!)result).length > 0)
            return lyrics_build_candidate ((!)result, "LyricsPlus", index);
        return null;
    }

    // Returns converted LRC+ text, "" on valid miss, null on error.
    private string? lyricsplus_parse_response (string raw) {
        try {
            var parser = new Json.Parser ();
            parser.load_from_data (raw);
            var root_obj = parser.get_root ()?.get_object ();
            if (root_obj == null) return null;
            var obj = (!)root_obj;
            // Error envelope: {"error": {"message": ...}} or {"error": "..."}
            if (obj.has_member ("error")) return "";
            if (!obj.has_member ("lyrics")) return "";
            var lyrics_node = obj.get_member ("lyrics");
            if (lyrics_node == null || ((!)lyrics_node).get_node_type () != Json.NodeType.ARRAY)
                return "";
            var lyrics_arr = ((!)lyrics_node).get_array ();
            if (((!)lyrics_arr).get_length () == 0) return "";
            var type = lyricsplus_get_string (obj, "type", "Line");
            // Section names for songPartIndex lookup, when the API provides them
            string[] song_parts = lyricsplus_get_song_parts (obj);
            var converted = lyricsplus_convert (((!)lyrics_arr), type, song_parts);
            if (converted.strip ().length == 0) return "";
            return converted;
        } catch (Error e) {
            return null;
        }
    }

    private string[] lyricsplus_get_song_parts (Json.Object obj) {
        string[] parts = {};
        if (!obj.has_member ("metadata")) return parts;
        var meta_node = obj.get_member ("metadata");
        if (meta_node == null || ((!)meta_node).get_node_type () != Json.NodeType.OBJECT)
            return parts;
        var meta = ((!)meta_node).get_object ();
        if (meta == null || !((!)meta).has_member ("songParts")) return parts;
        var arr_node = ((!)meta).get_member ("songParts");
        if (arr_node == null || ((!)arr_node).get_node_type () != Json.NodeType.ARRAY)
            return parts;
        var parts_arr = ((!)arr_node).get_array ();
        if (parts_arr == null) return parts;
        ((!)parts_arr).foreach_element ((a, i, node) => {
            var entry = node.get_object ();
            if (entry == null) { parts += ""; return; }
            parts += lyricsplus_get_string ((!)entry, "name", "");
        });
        return parts;
    }

    private string lyricsplus_convert (Json.Array lyrics_arr, string type, string[] song_parts) {
        if (type.down () == "word")
            return lyricsplus_convert_word (lyrics_arr, song_parts);
        return lyricsplus_convert_line (lyrics_arr, song_parts);
    }

    // Word-type entries are LINES with optional per-syllable timings:
    // {time, duration, text, syllabus: [{time, duration, text}],
    //  element: {singer, songPart / songPartIndex}}.
    // Emit one [ts]Text header plus a v2 timing line built from the
    // syllabus units, so syllable continuations ("be"+"fore") stay glued
    // and word boundaries (trailing space in source) stay split.
    private string lyricsplus_convert_word (Json.Array lyrics_arr, string[] song_parts) {
        var sb = new StringBuilder ();
        string last_section = "";
        lyrics_arr.foreach_element ((arr, i, node) => {
            var entry = node.get_object ();
            if (entry == null) return;
            var e = (!)entry;

            var text = lyricsplus_get_string (e, "text", "").strip ();
            if (text.length == 0) return;
            // One lyric line per entry: flatten any embedded newlines
            text = text.replace ("\n", " ").replace ("\r", " ").strip ();
            if (text.length == 0) return;

            var line_ms = lyricsplus_get_int (e, "time", -1);
            if (line_ms < 0) return;
            var line_dur = lyricsplus_get_int (e, "duration", -1);

            // Section marker when the song part changes (e.g. Verse->Chorus)
            var section = lyricsplus_get_section (e, song_parts);
            if (section.length > 0 && section != last_section) {
                sb.append ("[%s]\n".printf (section));
                last_section = section;
            } else if (section.length == 0) {
                last_section = "";
            }

            var singer = lyricsplus_get_singer (e);

            sb.append ("[%s]%s\n".printf (
                format_ms_as_timestamp (line_ms), text));

            // Timing line from syllabus units when present, else one unit
            // covering the whole line.
            var timing = new StringBuilder ();
            if (singer.length > 0 && singer != "v1")
                timing.append ("{%s}".printf (singer));

            var syl_node = e.has_member ("syllabus") ? e.get_member ("syllabus") : null;
            bool used_syllabus = false;
            if (syl_node != null && ((!)syl_node).get_node_type () == Json.NodeType.ARRAY) {
                var syl_arr = ((!)syl_node).get_array ();
                if (syl_arr != null && ((!)syl_arr).get_length () > 0) {
                    var syl = (!)syl_arr;
                    bool first = true;
                    bool prev_ended_word = true;
                    ((!)syl).foreach_element ((a2, j, snode) => {
                        var s_entry = snode.get_object ();
                        if (s_entry == null) return;
                        var s = (!)s_entry;
                        var raw_text = lyricsplus_get_string (s, "text", "");
                        if (raw_text.strip ().length == 0) return;
                        var start = lyricsplus_get_int (s, "time", -1);
                        if (start < 0) return;
                        var dur = lyricsplus_get_int (s, "duration", -1);
                        var word_text = encode_html_entities (raw_text.strip ());
                        if (!first && prev_ended_word) timing.append_c (' ');
                        // No separator when the previous unit was a syllable
                        // continuation (no trailing space in source).
                        int64 end_ms = dur > 0 ? start + dur : -1;
                        if (end_ms >= 0)
                            timing.append ("<%s,%s>%s".printf (
                                format_ms_as_timestamp (start),
                                format_ms_as_timestamp (end_ms),
                                word_text));
                        else
                            timing.append ("<%s>%s".printf (
                                format_ms_as_timestamp (start), word_text));
                        first = false;
                        prev_ended_word = raw_text.has_suffix (" ");
                    });
                    used_syllabus = !first;
                }
            }
            if (!used_syllabus) {
                int64 end_ms = line_dur > 0 ? line_ms + line_dur : -1;
                if (end_ms >= 0)
                    timing.append ("<%s,%s>%s".printf (
                        format_ms_as_timestamp (line_ms),
                        format_ms_as_timestamp (end_ms),
                        encode_html_entities (text)));
                else
                    timing.append ("<%s>%s".printf (
                        format_ms_as_timestamp (line_ms),
                        encode_html_entities (text)));
            }
            sb.append (timing.str);
            sb.append_c ('\n');
        });
        return sb.str;
    }

    private string lyricsplus_convert_line (Json.Array lyrics_arr, string[] song_parts) {
        var sb = new StringBuilder ();
        string last_section = "";
        lyrics_arr.foreach_element ((arr, i, node) => {
            var entry = node.get_object ();
            if (entry == null) return;
            var e = (!)entry;

            var text = lyricsplus_get_string (e, "text", "").strip ();
            if (text.length == 0) return;
            text = text.replace ("\n", " ").replace ("\r", " ").strip ();
            if (text.length == 0) return;

            var time_ms = lyricsplus_get_int (e, "time", -1);
            if (time_ms < 0) return;

            var section = lyricsplus_get_section (e, song_parts);
            if (section.length > 0 && section != last_section) {
                sb.append ("[%s]\n".printf (section));
                last_section = section;
            } else if (section.length == 0) {
                last_section = "";
            }

            sb.append ("[%s]%s\n".printf (format_ms_as_timestamp (time_ms), text));
        });
        return sb.str;
    }

    private string lyricsplus_get_section (Json.Object e, string[] song_parts) {
        if (!e.has_member ("element")) return "";
        var el_node = e.get_member ("element");
        if (el_node == null || ((!)el_node).get_node_type () != Json.NodeType.OBJECT)
            return "";
        var el = ((!)el_node).get_object ();
        if (el == null) return "";
        var direct = lyricsplus_get_string ((!)el, "songPart", "");
        if (direct.length > 0) return direct.strip ();
        if (((!)el).has_member ("songPartIndex")) {
            var idx = lyricsplus_get_int ((!)el, "songPartIndex", -1);
            if (idx >= 0 && idx < song_parts.length)
                return song_parts[idx].strip ();
        }
        return "";
    }

    private string lyricsplus_get_singer (Json.Object e) {
        if (!e.has_member ("element")) return "";
        var el_node = e.get_member ("element");
        if (el_node == null || ((!)el_node).get_node_type () != Json.NodeType.OBJECT)
            return "";
        var el = ((!)el_node).get_object ();
        if (el == null) return "";
        return lyricsplus_get_string ((!)el, "singer", "").strip ();
    }

    private string lyricsplus_get_string (Json.Object obj, string name, string fallback) {
        if (!obj.has_member (name)) return fallback;
        var node = obj.get_member (name);
        if (node == null || ((!)node).get_node_type () != Json.NodeType.VALUE)
            return fallback;
        var val = ((!)node).get_string ();
        return val ?? fallback;
    }

    private int64 lyricsplus_get_int (Json.Object obj, string name, int64 fallback) {
        if (!obj.has_member (name)) return fallback;
        var node = obj.get_member (name);
        if (node == null || ((!)node).get_node_type () != Json.NodeType.VALUE)
            return fallback;
        var n = (!)node;
        var gtype = n.get_value_type ();
        if (gtype == typeof (int64) || gtype == typeof (int) || gtype == typeof (long))
            return (int64) n.get_int ();
        if (gtype == typeof (double) || gtype == typeof (float))
            return (int64) n.get_double ();
        if (gtype == typeof (string)) {
            var s = n.get_string ();
            if (s != null) {
                int64 parsed;
                if (int64.try_parse ((!)s, out parsed))
                    return parsed;
            }
        }
        return fallback;
    }

    private async void lyricsplus_sleep_ms (uint ms, GLib.Cancellable? cancellable) {
        if (cancellable != null && ((!)cancellable).is_cancelled ()) return;
        var loop = new MainLoop ();
        Timeout.add (ms, () => { loop.quit (); return false; });
        ulong handler = 0;
        if (cancellable != null)
            handler = ((!)cancellable).cancelled.connect (() => loop.quit ());
        loop.run ();
        if (handler != 0 && cancellable != null)
            ((!)cancellable).disconnect (handler);
    }

    // Kept for back-compat; delegates to the cancellable-aware variant.
    private async void sleep_ms (uint ms) {
        yield lyricsplus_sleep_ms (ms, null);
    }
}
