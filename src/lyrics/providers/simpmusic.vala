namespace G4 {

    private string? get_all_string_metadata_text (string uri) {
        var file = GLib.File.new_for_uri (uri);
        if (!file.query_exists ()) {
            lyrics_log ("File does not exist: %s".printf (uri));
            return null;
        }

        var tags = G4.parse_gst_tags (file);
        if (tags == null) {
            lyrics_log ("No tags found for: %s".printf (uri));
            return null;
        }

        var sb = new GLib.StringBuilder ();
        var tag_list = (!)tags;

        string[] string_tags = {
            Gst.Tags.TITLE,
            Gst.Tags.ARTIST,
            Gst.Tags.ALBUM,
            Gst.Tags.ALBUM_ARTIST,
            Gst.Tags.GENRE,
            Gst.Tags.COMMENT,
            Gst.Tags.EXTENDED_COMMENT,
            Gst.Tags.COMPOSER,
            Gst.Tags.LYRICS,
            Gst.Tags.CONDUCTOR,
            Gst.Tags.PERFORMER,
            Gst.Tags.ENCODER,
            Gst.Tags.ENCODED_BY,
            Gst.Tags.COPYRIGHT,
            Gst.Tags.LICENSE,
            Gst.Tags.LOCATION,
            Gst.Tags.HOMEPAGE,
            Gst.Tags.DESCRIPTION,
            Gst.Tags.VERSION,
            Gst.Tags.ISRC,
            Gst.Tags.ORGANIZATION,
            Gst.Tags.CONTACT
        };

        foreach (var tag_name in string_tags) {
            var values = new GLib.GenericArray<string> ();
            G4.get_one_tag (tag_list, tag_name, values);

            foreach (var value in values) {
                var trimmed = value.strip ();
                if (trimmed.length > 0) {
                    sb.append (trimmed).append ("\n");
                    if (lyrics_debug_enabled) {
                        var truncated = trimmed.length > 100 ?
                            trimmed.substring (0, 100) + "..." : trimmed;
                        lyrics_log ("Metadata: %s = %s".printf (tag_name, truncated));
                    }
                }
            }
        }

        for (var i = 0; i < tag_list.n_tags (); i++) {
            var tag_name = tag_list.nth_tag_name (i);
            bool already_processed = false;
            foreach (var known_tag in string_tags) {
                if (tag_name == known_tag) {
                    already_processed = true;
                    break;
                }
            }

            if (!already_processed) {
                var values = new GLib.GenericArray<string> ();
                G4.get_one_tag (tag_list, tag_name, values);

                foreach (var value in values) {
                    var trimmed = value.strip ();
                    if (trimmed.length > 0) {
                        sb.append (trimmed).append ("\n");
                        if (lyrics_debug_enabled) {
                            var truncated = trimmed.length > 100 ?
                                trimmed.substring (0, 100) + "..." : trimmed;
                            lyrics_log ("Additional metadata: %s = %s".printf (tag_name, truncated));
                        }
                    }
                }
            }
        }

        if (sb.str.length > 0) {
            return sb.str;
        }
        return null;
    }

    private static string? extract_youtube_id_from_text (string text, out string? found_in_tag = null) {
        found_in_tag = null;

        if (text.length == 0) return null;

        try {
            var main_regex = "(?:youtu\\.be/|(?:music\\.)?youtube\\.com/(?:watch\\?v=|v/|embed/|shorts/))([A-Za-z0-9_-]{11})";
            var re = new GLib.Regex (main_regex, GLib.RegexCompileFlags.CASELESS | GLib.RegexCompileFlags.MULTILINE, 0);

            GLib.MatchInfo info;
            if (re.match (text, 0, out info)) {
                var yt_id = info.fetch (1);
                if (yt_id != null && ((!)yt_id).length == 11) {
                    return (!)yt_id;
                }
            }

            var purl_regex = "purl=(?:https?://)?(?:www\\.)?(?:music\\.)?(?:youtube\\.com/watch\\?v=|youtu\\.be/)([A-Za-z0-9_-]{11})";
            var purl_re = new GLib.Regex (purl_regex, GLib.RegexCompileFlags.CASELESS | GLib.RegexCompileFlags.MULTILINE, 0);

            if (purl_re.match (text, 0, out info)) {
                var yt_id = info.fetch (1);
                if (yt_id != null && ((!)yt_id).length == 11) {
                    return (!)yt_id;
                }
            }

            var param_regex = "(?:v=|/)([A-Za-z0-9_-]{11})(?:&|\\s|$|\")";
            var param_re = new GLib.Regex (param_regex, GLib.RegexCompileFlags.CASELESS | GLib.RegexCompileFlags.MULTILINE, 0);

            if (param_re.match (text, 0, out info)) {
                var yt_id = info.fetch (1);
                if (yt_id != null && ((!)yt_id).length == 11) {
                    return (!)yt_id;
                }
            }

        } catch (GLib.RegexError e) {
            GLib.message ("[Lyrics] Regex error in YouTube ID extraction: %s".printf (e.message));
        }

        return null;
    }

    private string? get_youtube_id_from_all_metadata (string uri) {
        lyrics_log ("Searching for YouTube ID in all metadata of: %s".printf (uri));

        var metadata_text = get_all_string_metadata_text (uri);
        if (metadata_text == null) {
            lyrics_log ("No metadata text available");
            return null;
        }

        var text = (!)metadata_text;

        if (lyrics_debug_enabled) {
            var truncated = text.length > 500 ? text.substring (0, 500) + "..." : text;
            lyrics_log ("Metadata text (%d chars):\n%s".printf (text.length, truncated));
        }

        string? found_in_tag = null;
        var yt_id = extract_youtube_id_from_text (text, out found_in_tag);

        if (yt_id != null) {
            lyrics_log ("Found YouTube ID in metadata: %s".printf ((!)yt_id));
            return yt_id;
        }

        lyrics_log ("No YouTube ID found in any metadata fields");
        return null;
    }

    private static string? extract_youtube_id (string comment) {
        string? dummy;
        return extract_youtube_id_from_text (comment, out dummy);
    }

    public async LyricsCandidate? provider_fetch_simpmusic (Music music, int duration_ms, Settings settings, int index, GLib.Cancellable? cancellable = null) {
        if (!settings.get_boolean ("lyrics-simpmusic-enabled")) {
            lyrics_log ("SimpMusic: disabled");
            return null;
        }

        string? yt_id = get_youtube_id_from_all_metadata (music.uri);
        if (yt_id == null) {
            yt_id = extract_youtube_id (music.comment);
            if (yt_id != null) {
                lyrics_log ("Found YouTube ID in comment field (fallback): %s".printf ((!)yt_id));
            }
        }
        if (yt_id == null) {
            lyrics_log ("SimpMusic: no YouTube ID found in any metadata, skipping");
            return null;
        }
        lyrics_log ("SimpMusic: using YouTube ID %s".printf ((!)yt_id));

        var url = "https://api-lyrics.simpmusic.org/v1/%s".printf (
            Uri.escape_string ((!)yt_id, null, false));
        var body = yield lyrics_http_get (url, cancellable);
        if (body == null) return null;
        try {
            var parser = new Json.Parser ();
            parser.load_from_data ((!)body);
            var root_obj = parser.get_root ()?.get_object ();
            if (root_obj == null) return null;
            var obj = (!)root_obj;
            if (!obj.get_boolean_member ("success")) return null;
            var data = obj.get_array_member ("data");
            if (data == null) return null;
            Json.Object? best = null;
            ((!)data).foreach_element ((arr, i, node) => {
                if (best != null) return;
                var track = node.get_object ();
                if (track == null) return;
                best = track;
            });
            if (best == null) return null;
            var b = (!)best;
            string? result = null;
            if (b.has_member ("richSyncLyrics"))
                result = b.get_string_member ("richSyncLyrics");
            if ((result == null || ((!)result).length == 0) && b.has_member ("syncedLyrics"))
                result = b.get_string_member ("syncedLyrics");
            if ((result == null || ((!)result).length == 0) && b.has_member ("plainLyrics"))
                result = b.get_string_member ("plainLyrics");
            if (result != null)
                return lyrics_build_candidate ((!)result, "SimpMusic", index);
            return null;
        } catch (Error e) {
            return null;
        }
    }
}
