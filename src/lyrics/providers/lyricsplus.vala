namespace G4 {

    public async LyricsCandidate? provider_fetch_lyricsplus (Music music, int duration_ms, Settings settings, int index, GLib.Cancellable? cancellable = null) {
        if (!settings.get_boolean ("lyrics-lyricsplus-enabled")) {
            lyrics_log ("LyricsPlus: disable");
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
            var url = "%s/v2/lyrics/get?title=%s&artist=%s&duration=%d&source=apple,lyricsplus,musixmatch,spotify,musixmatch-word,qq,deezer".printf (
                base_url,
                Uri.escape_string (music.title, null, false),
                Uri.escape_string (music.artist, null, false),
                duration_sec);
            if (music.album.length > 0)
                url += "&album=%s".printf (Uri.escape_string (music.album, null, false));
            for (var attempt = 0; attempt < 3; attempt++) {
                var body = yield lyrics_http_get_with_headers_allow_4xx (url, { { "User-Agent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" } }, cancellable);
                if (body == null) break;
                var raw = (!)body;
                if (raw.contains ("error code: 1027")) {
                    yield sleep_ms (1000 * (attempt + 1));
                    continue;
                }
                if (raw.contains ("error code: 1033"))
                    break;
                if (raw.length > 0) {
                    try {
                        var parser = new Json.Parser ();
                        parser.load_from_data (raw);
                        var root_obj = parser.get_root ()?.get_object ();
                        if (root_obj != null) {
                            var obj = (!)root_obj;
                            var type = obj.has_member ("type") ? obj.get_string_member ("type") : "Line";
                            if (obj.has_member ("lyrics")) {
                                var lyrics_arr = obj.get_array_member ("lyrics");
                                if (lyrics_arr != null && ((!)lyrics_arr).get_length () > 0) {
                                    result = convert_richsync_json ((!)lyrics_arr, type);
                                    break;
                                }
                            }
                        }
                    } catch (Error e) {
                    }
                }
                break;
            }
            if (result != null) break;
        }
        if (result != null)
            return lyrics_build_candidate ((!)result, "LyricsPlus", index);
        return null;
    }

    private string convert_richsync_json (Json.Array lyrics_arr, string type) {
        var sb = new StringBuilder ();
        if (type == "Word") {
            // v2 inline Variant A absolute: collect per-line word timings then emit
            // <mm:ss.xx:mm:ss.xx>Word <mm:ss.xx:mm:ss.xx>Word ...
            int64 line_start_ms = -1;
            string[] line_texts = {};
            int64[] line_times = {};

            void flush_line () {
                if (line_texts.length == 0) return;
                // header timestamp = first word's time (or line_start_ms)
                int64 header_ms = line_start_ms >= 0 ? line_start_ms : line_times[0];
                sb.append ("[%s]%s\n".printf (format_ms_as_timestamp (header_ms), string.joinv (" ", line_texts)));
                // word timing line: each word with start:end absolute
                for (var wi = 0; wi < line_texts.length; wi++) {
                    var start_ms = line_times[wi];
                    int64 end_ms;
                    if (wi + 1 < line_times.length) {
                        end_ms = line_times[wi + 1];
                    } else {
                        end_ms = start_ms + 300; // last word fallback
                    }
                    var start_ts = format_ms_as_timestamp (start_ms);
                    var end_ts = format_ms_as_timestamp (end_ms);
                    if (wi > 0) sb.append_c (' ');
                    sb.append ("<%s:%s>%s".printf (start_ts, end_ts, line_texts[wi]));
                }
                sb.append_c ('\n');
            }

            int64 prev_time = -1;
            lyrics_arr.foreach_element ((arr, i, node) => {
                var obj_n = node.get_object ();
                if (obj_n == null) return;
                var lyric_obj = (!)obj_n;

                var time_ms = lyric_obj.get_int_member ("time");
                var text = lyric_obj.get_string_member ("text");
                if (text.length == 0) return;

                bool new_line = (prev_time < 0) || (time_ms - prev_time > 2000);
                if (new_line && line_texts.length > 0) {
                    flush_line ();
                    line_texts = {};
                    line_times = {};
                    line_start_ms = -1;
                }
                if (line_start_ms < 0) line_start_ms = time_ms;
                line_texts += text;
                line_times += time_ms;

                prev_time = time_ms;
            });

            if (line_texts.length > 0) {
                flush_line ();
            }
        } else {
            lyrics_arr.foreach_element ((arr, i, node) => {
                var obj_n = node.get_object ();
                if (obj_n == null) return;
                var lyric_obj = (!)obj_n;

                var time_ms = lyric_obj.get_int_member ("time");
                var text = lyric_obj.get_string_member ("text");
                if (text.length == 0) return;

                int64 mins = time_ms / 1000 / 60;
                int64 secs = (time_ms / 1000) % 60;
                int64 ms = (time_ms % 1000) / 10;
                sb.append ("[%02lld:%02lld.%02lld]".printf (mins, secs, ms));
                sb.append (text);
                sb.append_c ('\n');
            });
        }
        return sb.str;
    }

    private async void sleep_ms (uint ms) {
        var loop = new MainLoop ();
        Timeout.add (ms, () => { loop.quit (); return false; });
        loop.run ();
    }
}
