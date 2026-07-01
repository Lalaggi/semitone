namespace G4 {

    public async LyricsCandidate? provider_fetch_musicbrainz (Music music, int duration_ms, Settings settings, int index, GLib.Cancellable? cancellable = null) {
        if (!settings.get_boolean ("lyrics-musicbrainz-enabled")) {
            lyrics_log ("MusicBrainz: disabled");
            return null;
        }

        // Step 1: Search for the recording to get its MBID
        // Use unquoted terms for fuzzy Lucene matching (quotes force exact match which can
        // fail when MusicBrainz has slightly different titles like "Epilouge" vs "Epilogue")
        var query = "recording:%s AND artist:%s".printf (
            Uri.escape_string (music.title, null, false),
            Uri.escape_string (music.artist, null, false));
        var search_url = "https://musicbrainz.org/ws/2/recording/?query=%s&fmt=json&limit=1".printf (
            Uri.escape_string (query, null, false));
        lyrics_log ("MusicBrainz: searching %s".printf (search_url));

        var body = yield lyrics_http_get (search_url, cancellable);
        if (body == null) return null;

        string? recording_id = null;
        try {
            var parser = new Json.Parser ();
            parser.load_from_data ((!)body);
            var root_obj = parser.get_root ()?.get_object ();
            if (root_obj == null) return null;
            var obj = (!)root_obj;

            var recordings = obj.get_array_member ("recordings");
            if (recordings == null || ((!)recordings).get_length () < 1) {
                lyrics_log ("MusicBrainz: no recordings found for query");
                return null;
            }
            var first_rec = ((!)recordings).get_element (0).get_object ();
            if (first_rec == null) return null;

            var score = ((!)first_rec).get_int_member ("score");
            if (score < 50) {
                lyrics_log ("MusicBrainz: best match score %lld too low, skipping".printf (score));
                return null;
            }

            recording_id = ((!)first_rec).get_string_member ("id");
            if (recording_id == null) return null;
            lyrics_log ("MusicBrainz: found recording %s (score=%lld)".printf ((!)recording_id, score));
        } catch (Error e) {
            lyrics_log ("MusicBrainz search parse error: %s".printf (e.message));
            return null;
        }

        // Step 2: Fetch the full recording with tags and work relationships.
        // Works carry type (Song/Instrumental/etc.) and language (eng/zxx/etc.) that are
        // more reliable for instrumental detection than recording-level tags.
        var inc = "tags+work-rels";
        var detail_url = "https://musicbrainz.org/ws/2/recording/%s?fmt=json&inc=%s".printf (
            (!)recording_id, inc);
        var detail_body = yield lyrics_http_get (detail_url, cancellable);
        if (detail_body == null) return null;

        try {
            var parser = new Json.Parser ();
            parser.load_from_data ((!)detail_body);
            var root_obj = parser.get_root ()?.get_object ();
            if (root_obj == null) return null;
            var rec = (!)root_obj;

            // Check 1: Recording-level tags for "instrumental"
            if (rec.has_member ("tags")) {
                var tags = rec.get_array_member ("tags");
                if (tags != null) {
                    var tags_arr = (!)tags;
                    for (var i = 0; i < tags_arr.get_length (); i++) {
                        var tag_obj = tags_arr.get_element (i).get_object ();
                        if (tag_obj == null) continue;
                        string? tag_name = ((!)tag_obj).get_string_member ("name");
                        if (tag_name != null && ((!)tag_name).ascii_ncasecmp ("instrumental", 13) == 0) {
                            lyrics_log ("MusicBrainz: recording tagged as instrumental");
                            LyricsCandidate c = { "[instrumental]", "MusicBrainz", {}, false, 0 };
                            return c;
                        }
                    }
                }
            }

            // Check 2: Work-level type and language indicators.
            // Works carry type (Song/Instrumental/...) and language (eng/zxx/...).
            // Only check the most relevant works (top 3 by title match) to avoid
            // flagging instrumental renditions of a primarily vocal track.
            // Language "zxx" = ISO 639-3 for "no linguistic content" → instrumental.
            // Work type "Instrumental" is definitive.
            string rec_title = rec.has_member ("title")
                ? rec.get_string_member ("title") : music.title;
            bool work_has_zxx = false;
            GenericArray<string> work_ids_to_check = new GenericArray<string> ();
            GenericArray<int> work_scores = new GenericArray<int> ();
            GenericArray<string> work_types = new GenericArray<string> ();
            GenericArray<string> work_languages = new GenericArray<string> ();

            if (rec.has_member ("relations")) {
                var rels = rec.get_array_member ("relations");
                if (rels != null) {
                    var rels_arr = (!)rels;
                    for (var ri = 0; ri < rels_arr.get_length (); ri++) {
                        var rel_obj = rels_arr.get_element (ri).get_object ();
                        if (rel_obj == null) continue;
                        if (!((!)rel_obj).has_member ("target-type")) continue;
                        var target_type = ((!)rel_obj).get_string_member ("target-type");
                        if (target_type != "work") continue;
                        var work_node = ((!)rel_obj).get_object_member ("work");
                        if (work_node == null) continue;
                        var w = (!)work_node;

                        if (!w.has_member ("id")) continue;
                        var wid = w.get_string_member ("id");
                        var w_title = w.has_member ("title") ? w.get_string_member ("title") : "";
                        var w_type = w.has_member ("type") ? w.get_string_member ("type") : "";
                        var w_lang = w.has_member ("language") ? w.get_string_member ("language") : "";

                        // Score relevance: prefer works whose title matches the recording
                        var score = 0;
                        if (rec_title.length > 0 && w_title.length > 0) {
                            var t_down = w_title.down ();
                            var r_down = rec_title.down ();
                            if (t_down == r_down) {
                                score = 100;  // exact title match
                            } else if (t_down.contains (r_down) || r_down.contains (t_down)) {
                                score = 50;   // partial match
                            }
                        }

                        // Insert in descending score order (keep top 3)
                        var insert_at = -1;
                        for (var si = 0; si < work_scores.length; si++) {
                            if (score > work_scores[si]) {
                                insert_at = si;
                                break;
                            }
                        }
                        if (insert_at != -1) {
                            work_ids_to_check.insert (insert_at, wid);
                            work_scores.insert (insert_at, score);
                            work_types.insert (insert_at, w_type);
                            work_languages.insert (insert_at, w_lang);
                        } else if (work_scores.length < 3) {
                            work_ids_to_check.add (wid);
                            work_scores.add (score);
                            work_types.add (w_type);
                            work_languages.add (w_lang);
                        }
                        if (work_scores.length > 3) {
                            work_ids_to_check.remove_index (work_scores.length - 1);
                            work_scores.remove_index (work_scores.length - 1);
                            work_types.remove_index (work_types.length - 1);
                            work_languages.remove_index (work_languages.length - 1);
                        }
                    }
                }
            }

            // Check the top relevant works for instrumental signals
            for (var wi = 0; wi < work_scores.length; wi++) {
                var w_type = work_types[wi];
                var w_lang = work_languages[wi];

                if (w_type.ascii_ncasecmp ("Instrumental", 13) == 0) {
                    lyrics_log ("MusicBrainz: work type is Instrumental (relevance score=%d)".printf (work_scores[wi]));
                    LyricsCandidate c = { "[instrumental]", "MusicBrainz", {}, false, 0 };
                    return c;
                }

                if (w_lang == "zxx") {
                    work_has_zxx = true;
                }
            }

            // If a relevant work has language "zxx" (no linguistic content), verify with
            // work-level tags, then trust the zxx signal.
            if (work_has_zxx) {
                for (var wi = 0; wi < work_ids_to_check.length; wi++) {
                    if (work_languages[wi] != "zxx") continue;
                    var work_url = "https://musicbrainz.org/ws/2/work/%s?fmt=json&inc=tags".printf (work_ids_to_check[wi]);
                    var work_body = yield lyrics_http_get (work_url, cancellable);
                    if (work_body == null) continue;

                    try {
                        var wp = new Json.Parser ();
                        wp.load_from_data ((!)work_body);
                        var work_root = wp.get_root ()?.get_object ();
                        if (work_root == null) continue;
                        var work_obj = (!)work_root;

                        if (work_obj.has_member ("tags")) {
                            var work_tags = work_obj.get_array_member ("tags");
                            if (work_tags != null) {
                                var work_tags_arr = (!)work_tags;
                                for (var j = 0; j < work_tags_arr.get_length (); j++) {
                                    var tag_obj = work_tags_arr.get_element (j).get_object ();
                                    if (tag_obj == null) continue;
                                    string? tag_name = ((!)tag_obj).get_string_member ("name");
                                    if (tag_name != null && ((!)tag_name).ascii_ncasecmp ("instrumental", 13) == 0) {
                                        lyrics_log ("MusicBrainz: work tagged as instrumental (zxx language)");
                                        LyricsCandidate c = { "[instrumental]", "MusicBrainz", {}, false, 0 };
                                        return c;
                                    }
                                }
                            }
                        }
                    } catch (Error e) {
                        lyrics_log ("MusicBrainz work tag parse error: %s".printf (e.message));
                    }
                }

                lyrics_log ("MusicBrainz: relevant work language is zxx - marking instrumental");
                LyricsCandidate c = { "[instrumental]", "MusicBrainz", {}, false, 0 };
                return c;
            }

            lyrics_log ("MusicBrainz: recording found but not instrumental");
            return null;
        } catch (Error e) {
            lyrics_log ("MusicBrainz detail parse error: %s".printf (e.message));
            return null;
        }
    }
}
