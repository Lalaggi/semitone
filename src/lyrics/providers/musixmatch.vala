namespace G4 {

    public async LyricsCandidate? provider_fetch_musixmatch (Music music, int duration_ms, Settings settings, int index) {
        if (!settings.get_boolean ("lyrics-musixmatch-enabled")) {
            lyrics_log ("Musixmatch: disabled");
            return null;
        }

        var mm_key = read_api_key_file ("musixmatch-api-key");
        if (mm_key == null) {
            lyrics_log ("Musixmatch: no API key, skipping");
            return null;
        }

        var search_url = "https://api.musixmatch.com/ws/1.1/track.search?q_track=%s&q_artist=%s&apikey=%s&page_size=1&page=1&s_track_rating=desc".printf (
            Uri.escape_string (music.title, null, false),
            Uri.escape_string (music.artist, null, false),
            Uri.escape_string ((!)mm_key, null, false));
        var search_body = yield lyrics_http_get (search_url);
        if (search_body == null) return null;
        try {
            var parser = new Json.Parser ();
            parser.load_from_data ((!)search_body);
            var root = parser.get_root ()?.get_object ();
            if (root == null) return null;
            var message = ((!)root).get_object_member ("message");
            if (message == null) return null;
            var body = ((!)message).get_object_member ("body");
            if (body == null) return null;
            var track_list = ((!)body).get_array_member ("track_list");
            if (track_list == null) return null;
            if (((!)track_list).get_length () == 0) return null;
            var track_obj = ((!)track_list).get_object_element (0);
            var track = track_obj.get_object_member ("track");
            if (track == null) return null;
            var track_id = ((!)track).get_int_member ("track_id");
            var lyrics_url = "https://api.musixmatch.com/ws/1.1/track.lyrics.get?track_id=%lld&apikey=%s".printf (
                track_id, Uri.escape_string ((!)mm_key, null, false));
            var lyrics_body = yield lyrics_http_get (lyrics_url);
            if (lyrics_body == null) return null;
            var parser2 = new Json.Parser ();
            parser2.load_from_data ((!)lyrics_body);
            var lroot = parser2.get_root ()?.get_object ();
            if (lroot == null) return null;
            var lmessage = ((!)lroot).get_object_member ("message");
            if (lmessage == null) return null;
            var lbody = ((!)lmessage).get_object_member ("body");
            if (lbody == null) return null;
            var lyrics_obj = ((!)lbody).get_object_member ("lyrics");
            if (lyrics_obj == null) return null;
            var lyrics_body_str = ((!)lyrics_obj).get_string_member ("lyrics_body");
            if (lyrics_body_str.strip ().length == 0) return null;
            return lyrics_build_candidate (lyrics_body_str, "Musixmatch", index);
        } catch (Error e) {
            lyrics_log ("Musixmatch error: %s".printf (e.message));
            return null;
        }
    }
}
