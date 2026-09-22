namespace G4 {

    private const string LASTFM_API_URL = "https://ws.audioscrobbler.com/2.0/";
    private const string LISTENBRAINZ_API_URL = "https://api.listenbrainz.org/1";

    // App key registered for Semitone (baked in as the GSettings defaults for
    // lastfm-api-key/lastfm-api-secret). Users can override with their own key
    // via GSettings or ~/.config/semitone/lastfm-api-key[-secret] files.
    private string lastfm_api_key (Settings settings) {
        var key = settings.get_string ("lastfm-api-key").strip ();
        if (key.length > 0) return key;
        return read_api_key_file ("lastfm-api-key") ?? "";
    }

    private string lastfm_api_secret (Settings settings) {
        var secret = settings.get_string ("lastfm-api-secret").strip ();
        if (secret.length > 0) return secret;
        return read_api_key_file ("lastfm-api-secret") ?? "";
    }

    private string scrobble_sig (HashTable<string, string> fields, string secret) {
        var keys = fields.get_keys ();
        keys.sort (strcmp);
        var sb = new StringBuilder ();
        var dbg = new StringBuilder ();
        foreach (var k in keys) {
            sb.append (k);
            sb.append (fields[k]);
            if (dbg.len > 0) dbg.append_c ('&');
            dbg.append (k);
            dbg.append_c ('=');
            dbg.append (fields[k]);
        }
        sb.append (secret);
        var hash = Checksum.compute_for_string (ChecksumType.MD5, sb.str);
        GLib.message ("[Scrobble] sig base: %s -> %s".printf (dbg.str, hash));
        return hash;
    }

    private class ScrobbleTrack : Object {
        public string uri = "";
        public string artist = "";
        public string title = "";
        public string album = "";
        public int duration_sec = 0;
        public int64 started_at = 0;
        public int64 played_ms = 0;
        public int64 last_pos_ms = -1;
        public bool scrobbled = false;
        public bool now_playing_sent = false;

        public bool eligible () {
            if (title.length == 0 || artist.length == 0) return false;
            if (artist == UNKNOWN_ARTIST) return false;
            if (duration_sec >= 30) {
                int threshold = int.min (duration_sec / 2, 240);
                return played_ms / 1000 >= threshold;
            }
            // Duration unknown (query failed): the 4-minute rule is still provably
            // correct — played >= 240s implies min(duration/2, 240) <= played.
            return played_ms >= 240000;
        }
    }

    public class ScrobbleManager : Object {
        private Application _app;
        private Settings _settings;
        private ScrobbleTrack? _current = null;
        private GenericArray<ScrobbleTrack> _pending = new GenericArray<ScrobbleTrack> ();
        private uint _retry_source = 0;
        private Cancellable? _auth_cancel = null;

        public bool lastfm_connecting { get; private set; default = false; }
        public string lastfm_status_text { get; private set; default = ""; }

        public ScrobbleManager (Application app) {
            _app = app;
            _settings = app.settings;
            app.music_changed.connect (on_music_changed);
            app.player.state_changed.connect (on_state_changed);
            app.player.position_updated.connect (on_position_updated);
            app.player.end_of_stream.connect (on_end_of_stream);
            app.player.duration_changed.connect (on_duration_changed);
            _settings.changed["lastfm-username"].connect (update_lastfm_status);
            _settings.changed["lastfm-session-key"].connect (update_lastfm_status);
            update_lastfm_status ();
        }

        // --- Last.fm browser auth (desktop flow: getToken -> approve -> getSession) ---

        public async void begin_lastfm_auth (Gtk.Window? parent) {
            if (lastfm_connecting) return;
            var api_key = lastfm_api_key (_settings);
            var api_secret = lastfm_api_secret (_settings);
            if (api_key.length == 0 || api_secret.length == 0) {
                lastfm_status_text = _("No API key configured — add one in ~/.config/semitone/lastfm-api-key");
                return;
            }
            lastfm_connecting = true;
            lastfm_status_text = _("Waiting for approval in browser…");
            _auth_cancel = new Cancellable ();
            var cancel = (!)_auth_cancel;
            try {
                var token_fields = new HashTable<string, string> (str_hash, str_equal);
                token_fields["method"] = "auth.getToken";
                token_fields["api_key"] = api_key;
                token_fields["api_sig"] = scrobble_sig (token_fields, api_secret);
                token_fields["format"] = "json";
                uint token_code;
                var token_resp = yield lyrics_http_post_form (LASTFM_API_URL, token_fields, cancel, out token_code);
                var token = parse_lastfm_string ((!)token_resp, "token");
                if (token == null) {
                    lastfm_status_text = _("Last.fm rejected the request (bad API key?)");
                    return;
                }
                var url = "https://www.last.fm/api/auth/?api_key=%s&token=%s".printf (
                    Uri.escape_string (api_key, null, true),
                    Uri.escape_string ((!)token, null, true));
                var launcher = new Gtk.UriLauncher (url);
                try {
                    yield launcher.launch (parent, cancel);
                } catch (Error e) {
                    lastfm_status_text = _("Could not open browser — approve at last.fm/api/auth");
                }
                // Poll getSession until the user approves (or 5 min timeout / cancel)
                int64 deadline = GLib.get_real_time () / 1000000 + 300;
                while (!cancel.is_cancelled () && GLib.get_real_time () / 1000000 < deadline) {
                    yield scrobble_sleep (3000, cancel);
                    if (cancel.is_cancelled ()) break;
                    var sess_fields = new HashTable<string, string> (str_hash, str_equal);
                    sess_fields["method"] = "auth.getSession";
                    sess_fields["api_key"] = api_key;
                    sess_fields["token"] = (!)token;
                    sess_fields["api_sig"] = scrobble_sig (sess_fields, api_secret);
                    sess_fields["format"] = "json";
                    uint sess_code;
                    var sess_resp = yield lyrics_http_post_form (LASTFM_API_URL, sess_fields, cancel, out sess_code);
                    if (sess_resp == null) continue; // not authorized yet (or offline)
                    var session = parse_lastfm_object ((!)sess_resp, "session");
                    if (session == null) continue;
                    var sess = (!)session;
                    var sk = sess.has_member ("key") ? sess.get_string_member ("key") : "";
                    var user = sess.has_member ("name") ? sess.get_string_member ("name") : "";
                    if (sk.length > 0) {
                        _settings.set_string ("lastfm-session-key", sk);
                        _settings.set_string ("lastfm-username", user);
                        _settings.set_boolean ("lastfm-enabled", true);
                        if (_current != null)
                            send_now_playing.begin ((!)_current);
                        break;
                    }
                }
                if (_settings.get_string ("lastfm-session-key").length == 0 && !cancel.is_cancelled ())
                    lastfm_status_text = _("Approval timed out — try Connect again");
            } catch (Error e) {
            } finally {
                lastfm_connecting = false;
                _auth_cancel = null;
                update_lastfm_status ();
            }
        }

        public void cancel_lastfm_auth () {
            _auth_cancel?.cancel ();
        }

        public void lastfm_logout () {
            cancel_lastfm_auth ();
            _settings.set_string ("lastfm-session-key", "");
            _settings.set_string ("lastfm-username", "");
            _settings.set_boolean ("lastfm-enabled", false);
        }

        private void update_lastfm_status () {
            if (lastfm_connecting) return;
            var user = _settings.get_string ("lastfm-username");
            if (_settings.get_string ("lastfm-session-key").length > 0)
                lastfm_status_text = user.length > 0
                    ? _("Connected as %s").printf (user) : _("Connected");
            else
                lastfm_status_text = _("Not connected");
        }

        // --- Playback tracking ---

        private void on_music_changed (Music? music) {
            commit_if_eligible ();
            if (music == null || ((!)music).title.length == 0) {
                _current = null;
                return;
            }
            var m = (!)music;
            var prev = _current;
            if (prev != null && ((!)prev).uri == m.uri) {
                // Same track, enriched tags — refresh metadata, keep progress
                var p = (!)prev;
                p.artist = m.artist_name;
                p.title = m.title;
                p.album = m.album;
                return;
            }
            var t = new ScrobbleTrack ();
            t.uri = m.uri;
            t.artist = m.artist_name;
            t.title = m.title;
            t.album = m.album;
            t.duration_sec = player_duration_sec ();
            t.started_at = GLib.get_real_time () / 1000000;
            _current = t;
            GLib.message ("[Scrobble] Now tracking: %s — %s (duration %ds)",
                t.title, t.artist, t.duration_sec);
            if (_app.player.playing)
                send_now_playing.begin (t);
        }

        private void on_state_changed (Gst.State state) {
            var t = _current;
            if (state == Gst.State.PLAYING && t != null && !((!)t).now_playing_sent)
                send_now_playing.begin ((!)t);
        }

        private void on_position_updated (Gst.ClockTime pos) {
            var t = _current;
            if (t == null || !_app.player.playing) return;
            var track = (!)t;
            if (pos == Gst.CLOCK_TIME_NONE) return;
            // Duration often isn't known at track start — pick it up once queryable
            if (track.duration_sec <= 0) {
                var d = _app.player.duration;
                if (d != Gst.CLOCK_TIME_NONE && (int) (d / Gst.SECOND) > 0) {
                    track.duration_sec = (int) (d / Gst.SECOND);
                    GLib.message ("[Scrobble] Duration resolved: %s — %ss",
                        track.title, track.duration_sec.to_string ());
                }
            }
            int64 ms = (int64) (pos / Gst.MSECOND);
            if (track.last_pos_ms < 0) {
                track.last_pos_ms = ms;
                return;
            }
            if (ms >= track.last_pos_ms)
                track.played_ms += ms - track.last_pos_ms;
            track.last_pos_ms = ms;
            if (!track.scrobbled && track.eligible ())
                commit_track.begin (track);
        }

        private void on_duration_changed (Gst.ClockTime duration) {
            if (_current != null && duration != Gst.CLOCK_TIME_NONE)
                ((!)_current).duration_sec = (int) (duration / Gst.SECOND);
        }

        private void on_end_of_stream () {
            commit_if_eligible ();
        }

        private int player_duration_sec () {
            var d = _app.player.duration;
            return d != Gst.CLOCK_TIME_NONE ? (int) (d / Gst.SECOND) : 0;
        }

        private void commit_if_eligible () {
            var t = _current;
            if (t == null) return;
            var track = (!)t;
            if (!track.scrobbled && track.eligible ())
                commit_track.begin (track);
        }

        private async void commit_track (ScrobbleTrack t) {
            if (t.scrobbled) return;
            t.scrobbled = true;
            GLib.message ("[Scrobble] Threshold reached, scrobbling: %s — %s (played %ds)",
                t.title, t.artist, (int) (t.played_ms / 1000));
            bool attempted = false;
            bool ok = true;
            if (_settings.get_boolean ("lastfm-enabled")
                    && _settings.get_string ("lastfm-session-key").length > 0) {
                attempted = true;
                bool sent = yield lastfm_scrobble (t);
                GLib.message ("[Scrobble] Last.fm scrobble %s: %s — %s",
                    sent ? "ok" : "FAILED", t.title, t.artist);
                if (!sent) ok = false;
            }
            if (_settings.get_boolean ("listenbrainz-enabled")
                    && _settings.get_string ("listenbrainz-token").length > 0) {
                attempted = true;
                bool sent = yield listenbrainz_scrobble (t);
                GLib.message ("[Scrobble] ListenBrainz scrobble %s: %s — %s",
                    sent ? "ok" : "FAILED", t.title, t.artist);
                if (!sent) ok = false;
            }
            if (!attempted) {
                GLib.message ("[Scrobble] No service enabled, dropping: %s — %s",
                    t.title, t.artist);
                return;
            }
            if (!ok) {
                if (_pending.length > 50)
                    _pending.remove_index (0);
                _pending.add (t);
                schedule_retry ();
            }
        }

        private void schedule_retry () {
            if (_retry_source != 0 || _pending.length == 0) return;
            _retry_source = Timeout.add_seconds (60, () => {
                _retry_source = 0;
                retry_pending.begin ();
                return false;
            });
        }

        private async void retry_pending () {
            var remaining = new GenericArray<ScrobbleTrack> ();
            foreach (var t in _pending) {
                bool ok = true;
                if (_settings.get_boolean ("lastfm-enabled")
                        && _settings.get_string ("lastfm-session-key").length > 0) {
                    if (!yield lastfm_scrobble (t)) ok = false;
                }
                if (_settings.get_boolean ("listenbrainz-enabled")
                        && _settings.get_string ("listenbrainz-token").length > 0) {
                    if (!yield listenbrainz_scrobble (t)) ok = false;
                }
                if (!ok) remaining.add (t);
            }
            _pending = remaining;
            schedule_retry ();
        }

        private async void send_now_playing (ScrobbleTrack t) {
            if (t.now_playing_sent) return;
            t.now_playing_sent = true;
            if (_settings.get_boolean ("lastfm-enabled")
                    && _settings.get_string ("lastfm-session-key").length > 0) {
                bool sent = yield lastfm_now_playing (t);
                GLib.message ("[Scrobble] Last.fm now-playing %s: %s — %s",
                    sent ? "ok" : "FAILED", t.title, t.artist);
            }
            if (_settings.get_boolean ("listenbrainz-enabled")
                    && _settings.get_string ("listenbrainz-token").length > 0) {
                bool sent = yield listenbrainz_now_playing (t);
                GLib.message ("[Scrobble] ListenBrainz now-playing %s: %s — %s",
                    sent ? "ok" : "FAILED", t.title, t.artist);
            }
        }

        // --- Last.fm API ---

        private async bool lastfm_now_playing (ScrobbleTrack t) {
            var fields = lastfm_unsigned_fields ("track.updateNowPlaying");
            if (fields == null) return false;
            var f = (!)fields;
            f["artist"] = t.artist;
            f["track"] = t.title;
            if (t.album.length > 0 && t.album != UNKNOWN_ALBUM) f["album"] = t.album;
            if (t.duration_sec > 0) f["duration"] = t.duration_sec.to_string ();
            return yield lastfm_call (f);
        }

        private async bool lastfm_scrobble (ScrobbleTrack t) {
            var fields = lastfm_unsigned_fields ("track.scrobble");
            if (fields == null) return false;
            var f = (!)fields;
            f["artist"] = t.artist;
            f["track"] = t.title;
            f["timestamp"] = t.started_at.to_string ();
            if (t.album.length > 0 && t.album != UNKNOWN_ALBUM) f["album"] = t.album;
            if (t.duration_sec > 0) f["duration"] = t.duration_sec.to_string ();
            return yield lastfm_call (f);
        }

        private HashTable<string, string>? lastfm_unsigned_fields (string method) {
            var api_key = lastfm_api_key (_settings);
            var api_secret = lastfm_api_secret (_settings);
            var sk = _settings.get_string ("lastfm-session-key");
            if (api_key.length == 0 || api_secret.length == 0 || sk.length == 0) return null;
            var fields = new HashTable<string, string> (str_hash, str_equal);
            fields["method"] = method;
            fields["api_key"] = api_key;
            fields["sk"] = sk;
            return fields;
        }

        private async bool lastfm_call (HashTable<string, string> fields) {
            // Sign LAST, over the complete param set: Last.fm excludes only
            // api_sig itself and format from the signature.
            var api_secret = lastfm_api_secret (_settings);
            fields["api_sig"] = scrobble_sig (fields, api_secret);
            fields["format"] = "json";
            uint code;
            var resp = yield lyrics_http_post_form (LASTFM_API_URL, fields, null, out code);
            if (resp == null || code == 0) {
                GLib.message ("[Scrobble] Last.fm %s: no response (network error)",
                    fields["method"]);
                return false;
            }
            if (code < 200 || code >= 300 || ((!)resp).contains ("\"error\"")) {
                var snippet = (!)resp;
                if (snippet.length > 200) snippet = snippet.substring (0, 200);
                GLib.message ("[Scrobble] Last.fm %s HTTP %u: %s",
                    fields["method"], code, snippet);
                return false;
            }
            return true;
        }

        // --- ListenBrainz API ---

        private async bool listenbrainz_now_playing (ScrobbleTrack t) {
            var token = _settings.get_string ("listenbrainz-token").strip ();
            if (token.length == 0) return false;
            var payload = listen_payload (t, false);
            var body = "{\"listen_type\":\"playing_now\",\"payload\":[%s]}".printf (payload);
            return yield listenbrainz_post (token, body);
        }

        private async bool listenbrainz_scrobble (ScrobbleTrack t) {
            var token = _settings.get_string ("listenbrainz-token").strip ();
            if (token.length == 0) return false;
            var payload = listen_payload (t, true);
            var body = "{\"listen_type\":\"single\",\"payload\":[%s]}".printf (payload);
            return yield listenbrainz_post (token, body);
        }

        private string listen_payload (ScrobbleTrack t, bool with_timestamp) {
            var sb = new StringBuilder ();
            sb.append_c ('{');
            if (with_timestamp)
                sb.append_printf ("\"listened_at\":%s,", t.started_at.to_string ());
            sb.append ("\"track_metadata\":{");
            sb.append_printf ("\"artist_name\":%s,", json_escape (t.artist));
            sb.append_printf ("\"track_name\":%s", json_escape (t.title));
            if (t.album.length > 0 && t.album != UNKNOWN_ALBUM)
                sb.append_printf (",\"release_name\":%s", json_escape (t.album));
            if (t.duration_sec > 0)
                sb.append_printf (",\"additional_info\":{\"duration_ms\":%d,\"media_player\":\"Semitone\",\"submission_client\":\"Semitone\"}",
                    t.duration_sec * 1000);
            else
                sb.append (",\"additional_info\":{\"media_player\":\"Semitone\",\"submission_client\":\"Semitone\"}");
            sb.append ("}}");
            return sb.str;
        }

        private async bool listenbrainz_post (string token, string body) {
            uint code;
            var resp = yield lyrics_http_post (LISTENBRAINZ_API_URL + "/submit-listens",
                "application/json", body,
                { { "Authorization", "Token " + token }, { "User-Agent", "Semitone/1.0" } },
                null, out code);
            if (resp == null || code == 0) {
                GLib.message ("[Scrobble] ListenBrainz: no response (network error)");
                return false;
            }
            if (code < 200 || code >= 300) {
                var snippet = (!)resp;
                if (snippet.length > 200) snippet = snippet.substring (0, 200);
                GLib.message ("[Scrobble] ListenBrainz HTTP %u: %s", code, snippet);
                return false;
            }
            return true;
        }

        private string json_escape (string s) {
            return "\"" + s.replace ("\\", "\\\\").replace ("\"", "\\\"")
                .replace ("\n", "\\n").replace ("\r", "\\r") + "\"";
        }
    }

    private string? parse_lastfm_string (string body, string member) {
        try {
            var parser = new Json.Parser ();
            parser.load_from_data (body);
            var root = parser.get_root ();
            if (root == null) return null;
            var obj = ((!)root).get_object ();
            if (obj == null || !((!)obj).has_member (member)) return null;
            return ((!)obj).get_string_member (member);
        } catch (Error e) {
            return null;
        }
    }

    private Json.Object? parse_lastfm_object (string body, string member) {
        try {
            var parser = new Json.Parser ();
            parser.load_from_data (body);
            var root = parser.get_root ();
            if (root == null) return null;
            var obj = ((!)root).get_object ();
            if (obj == null || !((!)obj).has_member (member)) return null;
            return ((!)obj).get_object_member (member);
        } catch (Error e) {
            return null;
        }
    }

    private async void scrobble_sleep (uint ms, Cancellable cancel) {
        if (cancel.is_cancelled ()) return;
        ulong handler = 0;
        handler = cancel.cancelled.connect (() => scrobble_sleep.callback ());
        Timeout.add (ms, () => {
            if (handler != 0) {
                cancel.disconnect (handler);
                scrobble_sleep.callback ();
            }
            return false;
        });
        yield;
    }
}
