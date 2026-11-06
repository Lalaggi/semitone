namespace G4 {

    private const string RECCOBEATS_API = "https://api.reccobeats.com/v1";
    private const string DEEZER_API = "https://api.deezer.com";
    // ReccoBeats audio analysis: values above this suggest instrumental
    // (see https://reccobeats.com/docs/documentation/Analysis/audio-features-extraction)
    private const double RECCOBEATS_INSTRUMENTAL_THRESHOLD = 0.5;

    // -----------------------------------------------------------------------
    // Shared ISRC extraction from local tags. ISRC is the strongest key we
    // have: LRC.red serves lyrics for it and ReccoBeats can resolve audio
    // features for it, so both providers want the same source of truth.
    // -----------------------------------------------------------------------

    // ISRC: 2-letter country + 3-char registrant + 2-digit year + 5-digit designation
    internal string? lyrics_find_isrc (string text) {
        try {
            var re = new Regex ("\\b[A-Z]{2}[A-Z0-9]{3}\\d{2}\\d{5}\\b");
            MatchInfo info;
            if (re.match (text.up (), 0, out info)) {
                var m = info.fetch (0);
                if (m != null && ((!)m).length == 12) return (!)m;
            }
        } catch (RegexError e) {}
        return null;
    }

    internal string? lyrics_isrc_for_music (Music music) {
        var found = lyrics_find_isrc (music.comment);
        if (found != null) return found;
        var metadata_text = get_all_string_metadata_text (music.uri);
        if (metadata_text == null) return null;
        return lyrics_find_isrc ((!)metadata_text);
    }

    // -----------------------------------------------------------------------
    // ReccoBeats
    // -----------------------------------------------------------------------

    internal Json.Object? reccobeats_json_object (string body) {
        try {
            var parser = new Json.Parser ();
            parser.load_from_data (body);
            return parser.get_root ()?.get_object ();
        } catch (Error e) {
            return null;
        }
    }

    internal double reccobeats_get_double (Json.Object obj, string name, double fallback) {
        if (!obj.has_member (name)) return fallback;
        var node = obj.get_member (name);
        if (node == null || ((!)node).get_node_type () != Json.NodeType.VALUE) return fallback;
        var gtype = ((!)node).get_value_type ();
        if (gtype == typeof (double) || gtype == typeof (float))
            return ((!)node).get_double ();
        if (gtype == typeof (int64) || gtype == typeof (int) || gtype == typeof (long) || gtype == typeof (int32))
            return ((!)node).get_int ();
        return fallback;
    }

    // The proved catalog (Spotify mirror) ranks by popularity and its search
    // is title-only, so a top hit may be a different song with the same name.
    // Only accept a result whose title AND artist match our metadata.
    internal bool reccobeats_track_matches (Json.Object track, string title, string artist) {
        if (title.length == 0 && artist.length == 0) return true;
        var t_title = unison_get_string_member (track, "trackTitle");
        bool title_ok = title.length == 0 || unison_text_matches (t_title, title);
        if (!title_ok) return false;
        if (artist.length == 0) return true;

        if (track.has_member ("artists")) {
            var member = (!)track.get_member ("artists");
            if (member.get_node_type () != Json.NodeType.ARRAY) return false;
            var artists = ((!)track).get_array_member ("artists");
            // A search hit can be a different song with the same title, so
            // match any credited artist against our metadata.
            for (var i = 0; i < ((!)artists).get_length (); i++) {
                var obj = ((!)artists).get_element (i).get_object ();
                if (obj == null) continue;
                if (unison_text_matches (unison_get_string_member ((!)obj, "name"), artist)) return true;
            }
        }
        return false;
    }

    // Same ISRC can span masters (single version vs album master, remixes).
    // The played duration pins which master we are listening to.
    internal Json.Object? reccobeats_pick_master (Json.Array content, int duration_ms, string title, string artist) {
        if (content.get_length () == 0) return null;
        var validated = new GenericArray<Json.Object> ();
        for (var i = 0; i < content.get_length (); i++) {
            var track = content.get_element (i).get_object ();
            if (track == null) continue;
            if (reccobeats_track_matches ((!)track, title, artist))
                validated.add ((!)track);
        }
        if (validated.length == 0) return null;
        if (duration_ms <= 0) return validated[0];
        var best = validated[0];
        long best_delta = -1;
        foreach (var track in validated) {
            long delta = (long) (reccobeats_get_double (track, "durationMs", 0.0) - duration_ms).abs ();
            if (best_delta < 0 || delta < best_delta) {
                best_delta = delta;
                best = track;
            }
        }
        return best;
    }

    private async double reccobeats_instrumentalness (string id, GLib.Cancellable? cancellable) {
        var url = "%s/track/%s/audio-features".printf (RECCOBEATS_API, Uri.escape_string (id, null, false));
        var body = yield lyrics_http_get (url, cancellable);
        if (body == null) return -1.0;
        var root = reccobeats_json_object ((!)body);
        if (root == null) return -1.0;
        return reccobeats_get_double ((!)root, "instrumentalness", -1.0);
    }

    private async LyricsCandidate? reccobeats_detect_by_id (string id, int duration_ms, string title, string artist, bool validate, int index, GLib.Cancellable? cancellable) {
        if (id.length == 0) return null;
        string recco_id;
        if (validate) {
            // Resolve the ID to real tracks so we can verify the match and
            // pick the master closest to what is playing; unknown IDs come
            // back as an empty content array with HTTP 200.
            var url = "%s/track?ids=%s".printf (RECCOBEATS_API, Uri.escape_string (id, null, false));
            var body = yield lyrics_http_get (url, cancellable);
            if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
            if (body == null) return null;
            var root = reccobeats_json_object ((!)body);
            if (root == null || !((!)root).has_member ("content")) return null;
            var content = ((!)root).get_array_member ("content");
            if (content == null) return null;
            var master = reccobeats_pick_master ((!)content, duration_ms, title, artist);
            if (master == null) {
                if (lyrics_debug_enabled)
                    lyrics_log ("ReccoBeats: id %s did not match '%s' by '%s'".printf (id, title, artist));
                return null;
            }
            recco_id = unison_get_string_member ((!)master, "id");
            if (recco_id.length == 0) return null;
        } else {
            recco_id = id;
        }

        double instrumentalness = yield reccobeats_instrumentalness (recco_id, cancellable);
        if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
        if (lyrics_debug_enabled)
            lyrics_log ("ReccoBeats: %s instrumentalness %.4f".printf (recco_id, instrumentalness));
        if (instrumentalness >= 0.0 && instrumentalness <= RECCOBEATS_INSTRUMENTAL_THRESHOLD) {
            // Not instrumental: a vocal track. No candidate, lyrics providers continue.
            return null;
        }
        if (instrumentalness > RECCOBEATS_INSTRUMENTAL_THRESHOLD)
            return lyrics_make_instrumental_candidate ("ReccoBeats", index);
        return null;
    }

    // Deezer is our fallback ISRC resolver: keyless, no auth, and its track
    // endpoint carries the ISRC the local tags often lack.
    private async string? reccobeats_deezer_isrc (Music music, GLib.Cancellable? cancellable) {
        var q = "%s %s".printf (music.title, music.artist).strip ();
        if (q.length < 2) return null;
        var search_url = "%s/search?q=%s&limit=3".printf (DEEZER_API, Uri.escape_string (q, null, false));
        var body = yield lyrics_http_get (search_url, cancellable);
        if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
        if (body == null) return null;
        var root = reccobeats_json_object ((!)body);
        if (root == null || !((!)root).has_member ("data")) return null;
        var results = ((!)root).get_array_member ("data");
        if (results == null) return null;

        // A search hit can be a different song with the same title ("Alpha"
        // has dozens), so verify artist and title before trusting an ISRC.
        // Two track lookups max keeps this cheap.
        int lookups = 0;
        for (var i = 0; i < ((!)results).get_length () && lookups < 2; i++) {
            var hit = ((!)results).get_element (i).get_object ();
            if (hit == null) continue;
            long dz_id = ((!)hit).has_member ("id") ? (long) ((!)hit).get_int_member ("id") : 0;
            if (dz_id <= 0) continue;
            lookups++;
            var track_url = "%s/track/%ld".printf (DEEZER_API, dz_id);
            var track_body = yield lyrics_http_get (track_url, cancellable);
            if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
            if (track_body == null) continue;
            var track = reccobeats_json_object ((!)track_body);
            if (track == null) continue;
            var dz_title = unison_get_string_member ((!)track, "title");
            string dz_artist = "";
            if (((!)track).has_member ("artist")) {
                var artist_obj = ((!)track).get_object_member ("artist");
                dz_artist = unison_get_string_member ((!)artist_obj, "name");
            }
            if (!unison_text_matches (dz_title, music.title) || !unison_text_matches (dz_artist, music.artist)) {
                if (lyrics_debug_enabled)
                    lyrics_log ("ReccoBeats: Deezer '%s' by '%s' did not match query".printf (dz_title, dz_artist));
                continue;
            }
            var isrc = unison_get_string_member ((!)track, "isrc");
            if (isrc.length == 12) return isrc;
        }
        return null;
    }

    // Last resort: ReccoBeats title search (popularity-ranked), validated
    // client-side by artist so a same-name track by anyone else can't win.
    private async LyricsCandidate? reccobeats_detect_by_search (Music music, int duration_ms, int index, GLib.Cancellable? cancellable) {
        if (music.title.strip ().length == 0) return null;
        var url = "%s/track/search?searchText=%s&size=25".printf (
            RECCOBEATS_API,
            Uri.escape_string (music.title, null, false));
        var body = yield lyrics_http_get (url, cancellable);
        if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
        if (body == null) return null;
        var root = reccobeats_json_object ((!)body);
        if (root == null || !((!)root).has_member ("content")) return null;
        var content = ((!)root).get_array_member ("content");
        if (content == null) return null;

        int tried = 0;
        for (var i = 0; i < ((!)content).get_length () && tried < 2; i++) {
            var track = ((!)content).get_element (i).get_object ();
            if (track == null) continue;
            var id = unison_get_string_member ((!)track, "id");
            if (id.length == 0) continue;
            if (!reccobeats_track_matches ((!)track, music.title, music.artist)) continue;
            tried++;
            var c = yield reccobeats_detect_by_id (id, duration_ms, music.title, music.artist, false, index, cancellable);
            if (c != null) return c;
        }
        return null;
    }

    // Instrumental detection only — this provider never produces lyrics.
    // Chain: local ISRC tags → Deezer search for the ISRC → ReccoBeats
    // title search. ReccoBeats search is title-only (a combined "title
    // artist" query returns nothing), hence the artist validation
    // followed there in reccobeats_track_matches ().
    public async LyricsCandidate? provider_fetch_reccobeats (Music music, int duration_ms, Settings settings, int index, GLib.Cancellable? cancellable = null) {
        var isrc = lyrics_isrc_for_music (music);
        if (isrc != null) {
            if (lyrics_debug_enabled)
                lyrics_log ("ReccoBeats: trying local ISRC %s".printf ((!)isrc));
            var c = yield reccobeats_detect_by_id ((!)isrc, duration_ms, music.title, music.artist, true, index, cancellable);
            if (c != null) return c;
        }

        var deezer_isrc = yield reccobeats_deezer_isrc (music, cancellable);
        if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
        if (deezer_isrc != null) {
            if (lyrics_debug_enabled)
                lyrics_log ("ReccoBeats: trying Deezer ISRC %s".printf ((!)deezer_isrc));
            var c = yield reccobeats_detect_by_id ((!)deezer_isrc, duration_ms, music.title, music.artist, true, index, cancellable);
            if (c != null) return c;
        }

        return yield reccobeats_detect_by_search (music, duration_ms, index, cancellable);
    }
}
