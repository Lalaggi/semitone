namespace G4 {

    public async LyricsCandidate? provider_fetch_lyricsplus (Music music, int duration_ms, Settings settings, int index, GLib.Cancellable? cancellable = null) {
        if (!settings.get_boolean ("lyrics-lyricsplus-enabled")) {
            lyrics_log ("LyricsPlus: disabled");
            return null;
        }

        var duration_sec = (int) (duration_ms / 1000);
        string[] base_urls = {
            "https://lyricsplus.prjktla.workers.dev",
            "https://lyricsplus.prjktla.my.id"
        };
        string? result = null;
        foreach (var base_url in base_urls) {
            var url = "%s/v2/lyrics/get?title=%s&artist=%s&duration=%d&source=apple,lyricsplus,musixmatch,spotify,musixmatch-word".printf (
                base_url,
                Uri.escape_string (music.title, null, false),
                Uri.escape_string (music.artist, null, false),
                duration_sec);
            if (music.album.length > 0) {
                url += "&album=%s".printf (Uri.escape_string (music.album, null, false));
            }
            for (var attempt = 0; attempt < 3; attempt++) {
                lyrics_log ("LyricsPlus: trying %s (attempt %d)".printf (base_url, attempt + 1));
                var body = yield lyrics_http_get_with_headers_allow_4xx (url, { { "User-Agent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" } }, cancellable);
                if (body == null) break;
                var raw = (!)body;
                if (raw.contains ("error code: 1027")) {
                    lyrics_log ("LyricsPlus: rate limited (1027), retrying...");
                    yield sleep_ms (1000 * (attempt + 1));
                    continue;
                }
                if (raw.contains ("error code: 1033")) {
                    lyrics_log ("LyricsPlus: tunnel error (1033), skipping endpoint");
                    break;
                }
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
                                    lyrics_log ("LyricsPlus: got lyrics from %s, type=%s".printf (base_url, type));
                                    result = convert_richsync_json ((!)lyrics_arr, type);
                                    break;
                                }
                            }
                        }
                    } catch (Error e) {
                        lyrics_log ("LyricsPlus: parse error from %s: %s".printf (base_url, e.message));
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
            int64 prev_time = -1;
            var current_line_words = new StringBuilder ();
            var current_line_text = new StringBuilder ();

            lyrics_arr.foreach_element ((arr, i, node) => {
                var obj_n = node.get_object ();
                if (obj_n == null) return;
                var lyric_obj = (!)obj_n;

                var time_ms = lyric_obj.get_int_member ("time");
                var text = lyric_obj.get_string_member ("text");
                if (text.length == 0) return;

                bool new_line = (prev_time < 0) || (time_ms - prev_time > 2000);
                if (new_line) {
                    if (current_line_text.len > 0) {
                        int64 mins = prev_time / 1000 / 60;
                        int64 secs = (prev_time / 1000) % 60;
                        int64 cs = (prev_time % 1000) / 10;
                        sb.append ("[%02lld:%02lld.%02lld]%s\n".printf (
                            mins, secs, cs, current_line_text.str.strip ()));
                        if (current_line_words.len > 0)
                            sb.append ("<%s>\n".printf (current_line_words.str));
                    }
                    current_line_text = new StringBuilder ();
                    current_line_words = new StringBuilder ();
                }

                if (current_line_text.len > 0) current_line_text.append_c (' ');
                current_line_text.append (text);

                double start_sec = time_ms / 1000.0;
                if (current_line_words.len > 0) current_line_words.append_c ('|');
                current_line_words.append ("%s:%.3f:%.3f".printf (text, start_sec, start_sec + 0.3));

                prev_time = time_ms;
            });

            if (current_line_text.len > 0) {
                int64 mins = prev_time / 1000 / 60;
                int64 secs = (prev_time / 1000) % 60;
                int64 cs = (prev_time % 1000) / 10;
                sb.append ("[%02lld:%02lld.%02lld]%s\n".printf (
                    mins, secs, cs, current_line_text.str.strip ()));
                if (current_line_words.len > 0)
                    sb.append ("<%s>\n".printf (current_line_words.str));
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
